#!/usr/bin/env python3
"""
fanctld — Apple Silicon smart fan control daemon
智能风扇温控守护进程：功耗前馈 + PI 反馈（抗饱和）+ 趋势阻尼 + 稳态自学习。

Control strategy 控制策略:
  Feedforward 前馈: time-averaged system power (≈ heat output) maps to a baseline
    RPM, scaled per profile — fans react to load before temperature moves.
  PI feedback 反馈: proportional + integral on (temp - target), with back-calculation
    anti-windup covering BOTH the output clamp and the slew-rate limiter.
  Trend damping 趋势阻尼: pushes back only while temperature is actively rising.
  Learning 自学习: at steady state the integral's standing bias migrates into the
    feedforward gain (per profile, persisted).

Security 安全:
  * executables live in a root-owned directory; ownership is verified before use
  * status/history/command files live under a root-owned runtime dir, never /tmp
  * command channel is a root:admin 0770 directory + strict verb whitelist
  * all writes use O_NOFOLLOW

Fail-safe 失效保护:
  * hardware state is reconciled to system control at startup
  * every exit path restores system fan control
  * a separate boot-time restore daemon covers SIGKILL / panic / power loss
"""
import json
import os
import re
import signal
import stat
import subprocess
import sys
import time

LIBEXEC = "/usr/local/libexec/fanctl"
RUNDIR = "/usr/local/var/fanctl"
SMCFAN = LIBEXEC + "/smcfan"
MACMON = next((p for p in (LIBEXEC + "/macmon", "/opt/homebrew/bin/macmon")
               if os.path.exists(p)), LIBEXEC + "/macmon")
LOG = "/var/log/fanctl.log"
STATUS = RUNDIR + "/status.json"
CMD = RUNDIR + "/cmd/cmd"
HISTORY = RUNDIR + "/history.jsonl"
MODEL = RUNDIR + "/model.json"
IOREG = "/usr/sbin/ioreg"
PMSET = "/usr/bin/pmset"

HIST_KEEP = 2400            # 修剪后保留的样本数（约 2 小时 @3s）
HIST_TRIM_AT = 4800
FAN_MIN_DEFAULT = 2000.0    # 探测失败时的保守回退值
FAN_MAX_DEFAULT = 7000.0

KI_BASE = 6.0
WRITE_BAND = 75.0
POWER_HOLD = 60.0           # 功耗读数失效时沿用上一有效值的时长（秒）
FF_GAIN_MIN = 60.0
FF_GAIN_MAX = 200.0
FF_GAIN_DEFAULT = 110.0
LEARN_RATE = 0.02
RELEASE_HOLD = 24           # 连续 N 拍低温才交还系统（~72s）
BATT_POLL = 30
MODE_REASSERT = 20          # 每 N 拍回读一次 SMC 模式，防止被外部复位
# SMC 保护态防护：过于频繁的访问（例如守护进程崩溃循环、或与第三方风扇工具争抢）
# 会把 AppleSMC 顶进保护状态——读数全 0、写入报错，停止访问数十秒后自愈。
# 检测到即退避，指数增长，期间只做低频探活，绝不继续敲打。
SMC_BACKOFF_BASE = 20.0
SMC_BACKOFF_MAX = 180.0

# 调速性格：quiet 有噪音天花板 / balanced 压住上升徐徐落温 / cool 尽快压下再回落保持
PROFILES = {
    # ff_margin: 前馈的温度裕度——温度低于 (目标−裕度) 时前馈完全不发力，
    #            越接近目标越放开。避免"功耗高但温度压得住"时无谓地冲高转速。
    "quiet":    dict(target=58.0, kp=45.0,  ki=4.0, kd=200.0, up=(100.0, 200.0, 350.0),
                     down=100.0, spike=25.0, ff_scale=0.70, cap_frac=0.75, ff_margin=10.0),
    "balanced": dict(target=55.0, kp=70.0,  ki=6.0, kd=300.0, up=(150.0, 300.0, 500.0),
                     down=120.0, spike=45.0, ff_scale=1.00, cap_frac=1.00, ff_margin=8.0),
    "cool":     dict(target=48.0, kp=130.0, ki=8.0, kd=450.0, up=(300.0, 500.0, 800.0),
                     down=150.0, spike=60.0, ff_scale=1.25, cap_frac=1.00, ff_margin=5.0),
}

state = {
    "manual": False, "rpm": 0.0, "written": 0.0, "integ": 0.0, "cool": 0,
    "override": None, "temp": 0.0, "power": 0.0, "act": 0, "err": None,
    "w_slow": 0.0, "w_ff": 0.0, "temps": [], "trend": 0.0, "last_temp": None,
    "profile": "balanced", "gains": {}, "model_dirty": False, "model_saved": 0.0,
    "fan_min": FAN_MIN_DEFAULT, "fan_max": FAN_MAX_DEFAULT, "fans": 0,
    "ticks": 0, "hist_n": 0, "watts_good": None, "tm": None, "machine": None,
}
macmon_proc = None


# ---------------------------------------------------------------- 基础设施

def log(msg):
    try:
        if os.path.exists(LOG) and os.path.getsize(LOG) > 1 << 20:
            os.truncate(LOG, 0)
        with open(LOG, "a") as f:
            f.write("%s %s\n" % (time.strftime("%F %T"), msg))
    except OSError:
        pass


def write_file_safe(path, data, mode=0o644):
    """O_NOFOLLOW 写入，绝不跟随符号链接（防 root 写被投毒的路径）。"""
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW
    fd = os.open(path, flags, mode)
    try:
        os.fchmod(fd, mode)
        os.write(fd, data.encode())
    finally:
        os.close(fd)


def append_file_safe(path, data, mode=0o644):
    flags = os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW
    fd = os.open(path, flags, mode)
    try:
        os.write(fd, data.encode())
    finally:
        os.close(fd)


def verify_executable(path):
    """执行前校验：必须是 root 拥有的普通文件，且不可被非 root 写。"""
    try:
        st = os.lstat(path)
    except OSError:
        return "missing: " + path
    if not stat.S_ISREG(st.st_mode):
        return "not a regular file: " + path
    if st.st_uid != 0:
        return "not owned by root: " + path
    if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        return "group/world writable: " + path
    d = os.path.dirname(path)
    try:
        dst = os.lstat(d)
    except OSError:
        return "missing dir: " + d
    if dst.st_uid != 0 or dst.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        return "insecure directory: " + d
    return None


# ---------------------------------------------------------------- SMC 访问

def smcfan(*args):
    try:
        return subprocess.run([SMCFAN, *args], capture_output=True, text=True, timeout=10)
    except Exception as e:
        log("smcfan error: %s" % e)
        return None


def probe_fans():
    """读取本机风扇数量与转速量程（机型自适应，替代硬编码）。"""
    r = smcfan("probe")
    if not r or r.returncode != 0:
        return False
    m = re.search(r"fans=(\d+)", r.stdout)
    state["fans"] = int(m.group(1)) if m else 0
    lo = re.search(r"min=([0-9.]+)", r.stdout)
    hi = re.search(r"max=([0-9.]+)", r.stdout)
    if lo and hi and float(hi.group(1)) > float(lo.group(1)) > 0:
        state["fan_min"] = float(lo.group(1))
        state["fan_max"] = float(hi.group(1))
    return state["fans"] > 0


def read_fan_field(key):
    r = smcfan("get", key)
    if r and r.returncode == 0:
        m = re.search(r"value=([0-9.]+)", r.stdout)
        if m:
            return float(m.group(1))
    return None


def smc_manual_mode():
    v = read_fan_field("F0Md")
    return None if v is None else int(v) == 1


def set_auto(reason=""):
    smcfan("auto")
    if state["manual"]:
        log("released to system control %s" % reason)
    state.update(manual=False, rpm=0.0, written=0.0, integ=0.0, cool=0,
                 trend=0.0, last_temp=None)


def smc_backoff(reason):
    """写入失败退避。持续失败通常源于睡眠唤醒后 SMC 把风扇键锁定（F0Md 读出异常值、
    写入返回 -126），此状态无法由软件解除，重启可恢复；期间仍继续温度监控。"""
    n = state["smc_fails"] = state.get("smc_fails", 0) + 1
    wait = min(SMC_BACKOFF_BASE * (2 ** (n - 1)), SMC_BACKOFF_MAX)
    state["smc_until"] = time.time() + wait
    if state.get("smc_first_fail") is None:
        state["smc_first_fail"] = time.time()
    stuck = time.time() - state["smc_first_fail"]
    mode = read_fan_field("F0Md")
    state["err"] = ("fan_control_locked" if stuck > 300 or (mode not in (0.0, 1.0, None))
                    else "fan_control_retry")
    if n <= 3 or n % 20 == 0:
        log("fan write rejected (%s), F0Md=%s, backing off %.0fs (fail #%d, stuck %.0fmin)"
            % (reason, mode, wait, n, stuck / 60))


def smc_ok():
    return time.time() >= state.get("smc_until", 0.0)


def write_rpm(rpm):
    if not smc_ok():
        return False
    r = smcfan("set", str(int(rpm)))
    if r and r.returncode == 3:              # 系统接管（F0Md 非 0/1）：不与之争抢
        n = state["smc_fails"] = state.get("smc_fails", 0) + 1
        state["smc_until"] = time.time() + min(SMC_BACKOFF_BASE * n, SMC_BACKOFF_MAX)
        state["err"] = "fan_control_locked"
        if n <= 2 or n % 20 == 0:
            log("system holds fan control (F0Md override) — standing by")
        return False
    if r and r.returncode == 0:
        state["written"] = rpm
        state["manual"] = True
        state["smc_fails"] = 0
        state["smc_first_fail"] = None
        state["err"] = None
        return True
    smc_backoff("write %d rpm" % rpm)
    return False


# ---------------------------------------------------------------- 传感器

def read_power_watts():
    try:
        out = subprocess.run([IOREG, "-rn", "AppleSmartBattery"],
                             capture_output=True, text=True, timeout=10).stdout
        m = re.search(r'"SystemPowerIn"=(\d+)', out)
        if m and int(m.group(1)) > 0:
            state["watts_good"] = (int(m.group(1)) / 1000.0, time.time())
            return state["watts_good"][0]
    except Exception:
        pass
    held = state["watts_good"]          # 遥测间歇失效：短时间沿用上次有效值
    if held and time.time() - held[1] < POWER_HOLD:
        return held[0]
    return None


def on_ac_power():
    try:
        out = subprocess.run([PMSET, "-g", "batt"], capture_output=True,
                             text=True, timeout=10).stdout
        return "AC Power" in out
    except Exception:
        return True                      # 判定失败按插电处理，宁多转不少转


# ---------------------------------------------------------------- 热模型辨识
#
# 动态能量守恒（不要求稳态，每个采样点都可用）：
#     C·dT/dt = P_in − h(rpm)·(T − T_amb)
#   其中 h(rpm) = k0 + k1·(rpm/1000)  [W/°C]  是本机固有散热能力曲线
#         C                            [J/°C] 是等效热容（解释温度滞后）
# 整理成线性回归：
#     P = C·(dT/dt) + k0·T + k1·(r·T) − k0·T_amb − k1·T_amb·r
#   特征 x = [dTs, T, r·T, 1, r]（dTs = dT/dt×100 做数值缩放），θ = [Cs, A, B, E, D]
#   则 C = Cs·100, k0 = A, k1 = B, T_amb = −E/A
# 用带遗忘因子的充分统计量在线累积，随积灰/散热垫/季节自适应。

TM_DECAY = 0.9995         # 每样本对历史统计量的遗忘因子（半衰期约 1400 样本 ≈ 1.2 小时）
TM_REFIT_EVERY = 40
TM_MIN_SAMPLES = 120      # 约 6 分钟连续数据
TM_RIDGE = 1e-5
TM_DIM = 5
# 关于可辨识性：闭环下转速由温度决定，(T) 与 (r·T) 高度共线，k0/k1/T_amb 的"拆分"
# 长期偏斜。实测（合成数据）表明这不影响我们真正使用的量——工作区间内的散热功率
# h·ΔT 预测误差约 4%。曾评估过叠加正弦抖动做持续激励：只有幅度大到 ±330 RPM 才
# 能显著改善拆分，那个幅度人耳可闻，得不偿失，故不采用；日常的手动定速/切换性格/
# 最大转速已提供足够的天然激励。


def machine_id():
    try:
        return subprocess.run(["/usr/sbin/sysctl", "-n", "hw.model"],
                              capture_output=True, text=True, timeout=5).stdout.strip()
    except Exception:
        return "unknown"


def machine_prior():
    """本机先验：优先查表，未知机型按风扇数与量程推算（风扇越多/转速越高散热越强）。"""
    mid = state.get("machine") or machine_id()
    if mid in MACHINE_PRIORS:
        return MACHINE_PRIORS[mid]
    cap, k0, k1 = TM_PRIOR_GENERIC
    scale = max(1.0, state.get("fans", 1)) * (state.get("fan_max", 7000.0) / 7826.0)
    return (cap, k0 * scale, k1 * scale)


def tm_init():
    return {"S": [[0.0] * TM_DIM for _ in range(TM_DIM)], "b": [0.0] * TM_DIM, "syy": 0.0,
            "n": 0.0, "since_fit": 0, "k0": None, "k1": None, "tamb": None,
            "cap": None, "rms": None}


def tm_features(temp, rpm, dtemp_dt):
    r = rpm / 1000.0
    return [dtemp_dt * 100.0, temp, r * temp, 1.0, r]


def tm_add(temp, rpm, watts, dtemp_dt):
    tm = state["tm"]
    x = tm_features(temp, rpm, dtemp_dt)
    for i in range(TM_DIM):
        for j in range(TM_DIM):
            tm["S"][i][j] = tm["S"][i][j] * TM_DECAY + x[i] * x[j]
        tm["b"][i] = tm["b"][i] * TM_DECAY + x[i] * watts
    tm["syy"] = tm["syy"] * TM_DECAY + watts * watts
    tm["n"] = tm["n"] * TM_DECAY + 1.0
    tm["since_fit"] += 1


def solve_lin(S, b, dim):
    """高斯消元（部分主元 + 岭正则），奇异返回 None。"""
    m = [[S[i][j] + (TM_RIDGE if i == j else 0.0) for j in range(dim)] + [b[i]] for i in range(dim)]
    for c in range(dim):
        p = max(range(c, dim), key=lambda r: abs(m[r][c]))
        if abs(m[p][c]) < 1e-12:
            return None
        m[c], m[p] = m[p], m[c]
        for r in range(dim):
            if r == c:
                continue
            f = m[r][c] / m[c][c]
            for k in range(c, dim + 1):
                m[r][k] -= f * m[c][k]
    return [m[i][dim] / m[i][i] for i in range(dim)]


def tm_project(a):
    """把 5 维统计量投影成"给定环境温度 a"下的 3 参正规方程。
    特征: f = [dTs, (T − a), r·(T − a)]，天然满足 h·ΔT 的物理约束。"""
    S, b = state["tm"]["S"], state["tm"]["b"]
    G = [[0.0] * 3 for _ in range(3)]
    G[0][0] = S[0][0]
    G[0][1] = G[1][0] = S[0][1] - a * S[0][3]
    G[0][2] = G[2][0] = S[0][2] - a * S[0][4]
    G[1][1] = S[1][1] - 2 * a * S[1][3] + a * a * S[3][3]
    G[1][2] = G[2][1] = S[1][2] - a * S[1][4] - a * S[3][2] + a * a * S[3][4]
    G[2][2] = S[2][2] - 2 * a * S[2][4] + a * a * S[4][4]
    c = [b[0], b[1] - a * b[3], b[2] - a * b[4]]
    return G, c


# 弱先验（物理量级）：闭环下转速与温度共线，靠先验稳住不可辨识方向
# 出厂先验 + 每机自学：不同芯片/机身（M1~M4、Pro/Max、14"/16"）散热能力差异很大，
# 无法用一套常数覆盖。策略是按机型给一个物理量级合理的先验作为起点，实测数据以弱
# 先验权重逐步覆盖它——新机第一分钟就有可用模型，用得越久越贴合这台机器的真实情况
# （积灰、散热垫、季节变化都会被持续跟踪）。先验按 hw.model 匹配，未知机型按风扇
# 数量与转速量程推算。
MACHINE_PRIORS = {                # hw.model → (C/100, k0, k1)
    "Mac16,8":  (2.0, 0.21, 0.10),   # MacBook Pro 14" M4 Pro（本机实测辨识）
    "Mac16,7":  (2.0, 0.21, 0.10),   # MacBook Pro 14" M4 Pro/Max
    "Mac16,6":  (2.0, 0.21, 0.10),   # MacBook Pro 14" M4 Max
    "Mac16,5":  (2.4, 0.26, 0.12),   # MacBook Pro 16" M4 Max
    "Mac16,1":  (1.6, 0.18, 0.09),   # MacBook Pro 14" M4
    "Mac15,3":  (1.6, 0.18, 0.09),   # MacBook Pro 14" M3
    "Mac15,7":  (2.0, 0.21, 0.10),   # MacBook Pro 14" M3 Pro/Max
    "Mac15,9":  (2.4, 0.26, 0.12),   # MacBook Pro 16" M3 Max
    "Mac14,5":  (2.0, 0.21, 0.10),   # MacBook Pro 14" M2 Pro/Max
    "Mac14,6":  (2.4, 0.26, 0.12),   # MacBook Pro 16" M2 Pro/Max
    "MacBookPro18,3": (2.0, 0.21, 0.10),   # 14" M1 Pro/Max
    "MacBookPro18,1": (2.4, 0.26, 0.12),   # 16" M1 Pro/Max
    "Mac14,12": (2.6, 0.30, 0.14),   # Mac mini M2 Pro
    "Mac16,11": (2.6, 0.30, 0.14),   # Mac mini M4 Pro
}
TM_PRIOR_GENERIC = (2.0, 0.15, 0.08)
TM_PRIOR_W = (3.0, 0.02, 0.02)    # 逐参数先验权重：热容强先验，散热系数交给数据


def tm_solve_at(a, cap_s):
    """给定环境温度 a 与已知热容，解 [k0, k1] 与残差平方和。
    热容在闭环噪声下不可辨识（自由求解会得到非物理的负值），因此固定为机型先验，
    作为已知量从方程左边移除：y' = P − C·dT/dt，再对 y' 做二参回归。"""
    S, b, tm = state["tm"]["S"], state["tm"]["b"], state["tm"]
    # 特征 f1 = T − a = x1 − a·x3, f2 = r·T − a·r = x2 − a·x4
    G = [[0.0, 0.0], [0.0, 0.0]]
    G[0][0] = S[1][1] - 2 * a * S[1][3] + a * a * S[3][3]
    G[0][1] = G[1][0] = S[1][2] - a * S[1][4] - a * S[3][2] + a * a * S[3][4]
    G[1][1] = S[2][2] - 2 * a * S[2][4] + a * a * S[4][4]
    # Σf·y' = Σf·y − C·Σf·x0
    c = [b[1] - a * b[3] - cap_s * (S[1][0] - a * S[3][0]),
         b[2] - a * b[4] - cap_s * (S[2][0] - a * S[4][0])]
    prior = machine_prior()
    n = max(tm["n"], 1.0)
    lam = [TM_PRIOR_W[1] * n, TM_PRIOR_W[2] * n]
    A = [[G[i][j] + (lam[i] if i == j else 0.0) for j in range(2)] for i in range(2)]
    rhs = [c[0] + lam[0] * prior[1], c[1] + lam[1] * prior[2]]
    th = solve_lin(A, rhs, 2)
    if not th:
        return None
    syy2 = tm["syy"] - 2 * cap_s * b[0] + cap_s * cap_s * S[0][0]
    sse = syy2
    for i in range(2):
        sse -= 2 * th[i] * c[i]
        for j in range(2):
            sse += th[i] * th[j] * G[i][j]
    return th, max(sse, 0.0)


def tm_fit():
    """剖面似然：环境温度一维搜索，内层解析求 [k0,k1]，热容取机型先验。"""
    tm = state["tm"]
    if tm["n"] < TM_MIN_SAMPLES:
        return
    cap_s = machine_prior()[0]
    best = None
    a = 10.0
    while a <= 40.0:
        r = tm_solve_at(a, cap_s)
        if r:
            th, sse = r
            if th[0] > 0 and th[1] > 0 and (best is None or sse < best[1]):
                best = ((th, a), sse)
        a += 0.5
    if best is None:
        return
    (th, tamb), sse = best
    k0, k1 = th
    if not (0.02 <= k0 <= 5.0 and 0.01 <= k1 <= 3.0):
        return
    tm.update(k0=k0, k1=k1, tamb=tamb, cap=cap_s * 100.0,
              rms=(sse / max(tm["n"], 1.0)) ** 0.5)
    log("thermal model: h=%.3f+%.3f·(rpm/1000) W/°C, T_amb=%.1f°C (C=%.0f prior), "
        "rms=%.1fW, n=%.0f" % (k0, k1, tamb, tm["cap"], tm["rms"], tm["n"]))


def tm_dissipation(temp, rpm):
    """当前转速与温度下的散热功率（W）。模型未收敛时用机型先验估算（标记 prior）。"""
    tm = state["tm"]
    if not temp:
        return None
    if tm["k0"] is None:
        _, k0, k1 = machine_prior()
        return max(0.0, (k0 + k1 * (rpm / 1000.0)) * (temp - 25.0))
    return max(0.0, (tm["k0"] + tm["k1"] * (rpm / 1000.0)) * (temp - tm["tamb"]))


def tm_required_rpm(watts, target):
    """稳态守住目标温度所需的转速；模型未就绪或物理上不可达返回 None。"""
    tm = state["tm"]
    if tm["k0"] is None or tm["k1"] <= 0:
        return None
    dt = max(target - tm["tamb"], 5.0)
    return max(0.0, (watts / dt - tm["k0"]) / tm["k1"] * 1000.0)


# ---------------------------------------------------------------- 模型持久化

def prof():
    return PROFILES[state["profile"]]


def ff_gain():
    return state["gains"].get(state["profile"], FF_GAIN_DEFAULT)


def load_model():
    if state["tm"] is None:
        state["tm"] = tm_init()
    try:
        with open(MODEL) as f:
            m = json.load(f)
    except (OSError, ValueError):
        return
    if m.get("machine") and m["machine"] != state["machine"]:
        log("machine changed (%s → %s) — relearning thermal model"
            % (m["machine"], state["machine"]))
        state["tm"] = tm_init()
        return
    tmj = m.get("thermal")
    if isinstance(tmj, dict) and tmj.get("S"):
        S, b = tmj.get("S"), tmj.get("b")
        ok = (isinstance(S, list) and len(S) == TM_DIM
              and all(isinstance(r, list) and len(r) == TM_DIM for r in S)
              and isinstance(b, list) and len(b) == TM_DIM)
        if ok:
            try:
                state["tm"].update(S=S, b=b, n=float(tmj["n"]),
                                   syy=float(tmj.get("syy", 0.0)))
                tm_fit()
            except (KeyError, TypeError, ValueError):
                state["tm"] = tm_init()
        else:
            log("thermal stats shape changed (%s→%s) — relearning" %
                (len(S) if isinstance(S, list) else "?", TM_DIM))
    gains = m.get("gains")
    if isinstance(gains, dict):          # 每档独立增益（目标温度不同，不可共用）
        for k, v in gains.items():
            if k in PROFILES:
                state["gains"][k] = max(FF_GAIN_MIN, min(FF_GAIN_MAX, float(v)))
    elif isinstance(m.get("ff_gain"), (int, float)):   # v1.9 及更早的单值格式
        g = max(FF_GAIN_MIN, min(FF_GAIN_MAX, float(m["ff_gain"])))
        state["gains"]["balanced"] = g
    if m.get("profile") in PROFILES:
        state["profile"] = m["profile"]
    log("model loaded: profile=%s gains=%s" % (state["profile"], state["gains"]))


def save_model(force=False):
    now = time.time()
    if not force and (not state["model_dirty"] or now - state["model_saved"] < 300):
        return
    try:
        os.makedirs(RUNDIR, exist_ok=True)
        write_file_safe(MODEL, json.dumps({
            "gains": {k: round(v, 2) for k, v in state["gains"].items()},
            "profile": state["profile"], "updated": now, "machine": state["machine"],
            "thermal": {"S": state["tm"]["S"], "b": state["tm"]["b"],
                        "syy": state["tm"]["syy"], "n": state["tm"]["n"],
                        "dim": TM_DIM}}))
        state["model_dirty"] = False
        state["model_saved"] = now
    except OSError:
        pass


# ---------------------------------------------------------------- IPC

def write_status(mode):
    append_history(mode)
    live = mode != "battery"             # 电池模式不采样：温度/功耗置空，UI 显示 —
    try:
        payload = {
            "mode": mode,
            "temp": round(state["temp"], 1) if live else None,
            "power": round(state["power"], 1) if live else None,
            "rpm": int(state["rpm"]) if state["manual"] else None,
            "act": state["act"] if state["act"] > 0 else None,
            "profile": state["profile"],
            "fanMin": int(state["fan_min"]), "fanMax": int(state["fan_max"]),
            "fans": state["fans"], "err": state["err"],
            # UI 用它把功耗折合成"守住当前目标温度所需的转速"，两线才可直接比较
            "ffGain": round(ff_gain() * prof()["ff_scale"], 1),
            "target": prof()["target"],
            "tmSamples": int(state["tm"]["n"]), "tmNeed": TM_MIN_SAMPLES,
            "tmLearned": state["tm"]["k0"] is not None,
            "machine": state["machine"],
            "thermal": ({"k0": round(state["tm"]["k0"], 4),
                         "k1": round(state["tm"]["k1"], 4),
                         "tamb": round(state["tm"]["tamb"], 1),
                         "cap": round(state["tm"]["cap"] or 0, 0),
                         "n": int(state["tm"]["n"])}
                        if state["tm"]["k0"] is not None else None),
            "diss": (round(d, 1) if (d := tm_dissipation(state["temp"], state["act"])) else None),
            "ts": time.time(),
        }
        write_file_safe(STATUS + ".tmp", json.dumps(payload))
        os.replace(STATUS + ".tmp", STATUS)
    except OSError:
        pass


def append_history(mode):
    if mode == "battery":                 # 电池模式不采样
        return
    try:
        append_file_safe(HISTORY, json.dumps({
            "ts": round(time.time(), 1), "temp": round(state["temp"], 1),
            "rpm": state["act"] if state["act"] > 0 else None,
            "w": round(state["power"], 1),
            "mode": mode, "pf": state["profile"]}) + "\n")
        state["hist_n"] += 1
        if state["hist_n"] >= 400:
            state["hist_n"] = 0
            with open(HISTORY) as f:
                lines = f.readlines()
            if len(lines) > HIST_TRIM_AT:
                write_file_safe(HISTORY, "".join(lines[-HIST_KEEP:]))
    except OSError:
        pass


def read_command():
    """消费命令文件。目录权限限定为 root:admin 0770；动词仍走严格白名单。
    合法: pause | resume | max | set <rpm> | profile <name> | target <c> | resetmodel"""
    try:
        with open(CMD) as f:
            verb = f.read(64).strip()
        os.unlink(CMD)
    except OSError:
        return None
    if verb in ("pause", "resume", "max", "resetmodel"):
        return verb
    if verb.startswith("profile ") and verb.split()[1] in PROFILES:
        return verb
    if re.fullmatch(r"set \d{3,5}", verb) or re.fullmatch(r"target \d{2}", verb):
        return verb
    return None


# ---------------------------------------------------------------- 控制

def handle_command():
    verb = read_command()
    if verb is None:
        return
    if verb == "pause":
        state["override"] = "pause"
        set_auto("(paused by user)")
    elif verb == "resume":
        state["override"] = None
        log("override cleared, smart control resumed")
    elif verb == "resetmodel":
        state["gains"] = {}
        state["integ"] = 0.0
        state["model_dirty"] = True
        save_model(force=True)
        log("learned model reset")
    elif verb.startswith("profile "):
        state["profile"] = verb.split()[1]
        state["override"] = None         # 选性格即进入智能调速
        state.update(integ=0.0, trend=0.0, last_temp=None, temps=[], cool=0)
        state["model_dirty"] = True
        save_model(force=True)
        log("profile -> %s (smart control active)" % state["profile"])
    elif verb.startswith("target "):
        t = float(verb.split()[1])
        if 40.0 <= t <= 80.0:
            PROFILES[state["profile"]]["target"] = t
            state["integ"] = 0.0
            log("target -> %.0f°C (profile %s)" % (t, state["profile"]))
    else:                                # max / set <rpm> → 手动定速
        rpm = state["fan_max"] if verb == "max" else float(verb.split()[1])
        rpm = max(state["fan_min"], min(state["fan_max"], rpm))
        state["override"] = "custom"
        state["rpm"] = rpm
        # 手动定速期间控制器状态清零，避免切回智能档时残留积分瞬间顶满
        state.update(integ=0.0, trend=0.0, last_temp=None, temps=[], cool=0)
        write_rpm(rpm)
        log("override: manual %d rpm" % rpm)


def control_tick(temp):
    state["ticks"] += 1
    state["temp"] = temp
    if not smc_ok():                     # 退避期：不写 SMC，但温度监控照常
        state["act"] = 0
        state["power"] = read_power_watts() or 0.0
        write_status("degraded")
        return
    watts = read_power_watts()
    state["power"] = watts or 0.0
    act = read_fan_field("F0Ac")
    state["act"] = int(act) if act else 0


    handle_command()

    if state["override"] == "pause":
        write_status("paused")
        return

    if state["override"] == "custom":
        if abs(state["written"] - state["rpm"]) >= 1 or state["ticks"] % MODE_REASSERT == 0:
            write_rpm(state["rpm"])      # 周期性重申，抵抗睡眠唤醒/外部复位
        write_status("custom")
        return

    fan_min, fan_max = state["fan_min"], state["fan_max"]
    p = prof()

    if not state["manual"]:
        if temp >= p["target"] - 2.0:
            cur = read_fan_field("F0Ac") or fan_min
            state["rpm"] = max(cur, fan_min)
            state.update(integ=0.0, cool=0, trend=0.0, last_temp=temp)
            write_rpm(state["rpm"])
            log("temp=%.1f engage from %d rpm" % (temp, state["rpm"]))
        write_status("manual" if state["manual"] else "auto")
        return

    # 智能调速期间周期性校验 SMC 仍在手动档（睡眠唤醒后可能被复位）
    if state["ticks"] % MODE_REASSERT == 0 and smc_manual_mode() is False:
        log("SMC reverted to auto — reasserting manual control")
        write_rpm(state["rpm"])

    err = temp - p["target"]
    state["integ"] = max(-1500.0, min(fan_max - fan_min, state["integ"] + p["ki"] * err))

    # 趋势阻尼：只对"温度正在上升"发力，升势止住即退出
    d = temp - (state["last_temp"] if state["last_temp"] is not None else temp)
    state["last_temp"] = temp
    state["trend"] = state["trend"] * 0.5 + d * 0.5
    damp = p["kd"] * max(0.0, state["trend"])

    # 功耗突增预压制 + 前馈区间均值（发热量按时间积分口径）
    w = watts or 0.0
    if state["w_slow"] <= 0:
        state["w_slow"] = w
    if state["w_ff"] <= 0:
        state["w_ff"] = w
    dw = w - state["w_slow"]
    spike = min(1000.0, max(0.0, dw - 3.0) * p["spike"]) if dw > 3.0 else 0.0
    state["w_slow"] = state["w_slow"] * 0.90 + w * 0.10
    state["w_ff"] = state["w_ff"] * 0.85 + w * 0.15

    # 热模型辨识：dT/dt 用最近 5 个采样点的最小二乘斜率（无相位滞后，抗传感器噪声）
    now = time.time()
    hist = state.setdefault("dtq", [])
    hist.append((now, temp))
    del hist[:-5]
    if w > 8 and state["act"] > 0 and len(hist) == 5:
        t0 = hist[0][0]
        xs = [p[0] - t0 for p in hist]
        ys = [p[1] for p in hist]
        mx = sum(xs) / 5.0
        my = sum(ys) / 5.0
        den = sum((x - mx) ** 2 for x in xs)
        dtemp_dt = (sum((xs[i] - mx) * (ys[i] - my) for i in range(5)) / den) if den > 1e-6 else 0.0
        tm_add(temp, state["act"], w, dtemp_dt)
        if state["tm"]["since_fit"] >= TM_REFIT_EVERY:
            state["tm"]["since_fit"] = 0
            tm_fit()
            state["model_dirty"] = True

    # 前馈需求调制：整机功耗里有相当部分（屏幕/外设/充电损耗）并不进散热片，
    # 纯按瓦数拉转速会系统性过冲。温度距目标越远、且没有上升趋势，前馈越收敛；
    # 逼近目标或正在爬升时才完全放开——"压得住就不必吼"。
    margin = p["ff_margin"]
    demand = (temp - (p["target"] - margin)) / margin
    if state["trend"] > 0.05:                 # 正在明显爬升：提前放开，保留预判能力
        demand += min(0.5, state["trend"] * 4.0)
    demand = max(0.0, min(1.0, demand))
    state["ff_demand"] = demand
    ff_full = fan_min + max(0.0, state["w_ff"] - 8.0) * ff_gain() * p["ff_scale"]
    ff = fan_min + (ff_full - fan_min) * demand

    # 稳态自学习：把积分携带的常差按当前性格迁进前馈增益（精确回代，保持指令连续）
    state["temps"] = (state["temps"] + [temp])[-8:]
    if (len(state["temps"]) == 8 and max(state["temps"]) - min(state["temps"]) < 0.8
            and fan_min + 60 < state["rpm"] < fan_max - 60 and state["w_ff"] > 10
            and demand > 0.8):
        base = max(state["w_ff"] - 8.0, 2.0)
        old = ff_gain()
        new = max(FF_GAIN_MIN, min(FF_GAIN_MAX, old + LEARN_RATE * state["integ"] / base))
        if abs(new - old) > 0.005:
            state["gains"][state["profile"]] = new
            state["integ"] -= base * (new - old) * p["ff_scale"]
            state["model_dirty"] = True
    save_model()

    cmd_raw = ff + spike + damp + p["kp"] * err + state["integ"]

    # 抗饱和反算：输出钳位与斜率限幅都是饱和环节，两者都要泄积分
    ceil = fan_min + (fan_max - fan_min) * p["cap_frac"]
    if cmd_raw > ceil:
        state["integ"] -= 0.06 * (cmd_raw - ceil)
    elif cmd_raw < fan_min:
        state["integ"] += 0.06 * (fan_min - cmd_raw)
    cmd = max(fan_min, min(ceil, cmd_raw))

    rate_up = p["up"][2] if err > 15 else p["up"][1] if err > 5 else p["up"][0]
    # 降速斜率随"温度低于目标的富余量"放宽：温度已经压得很低还维持高转速纯属噪音，
    # 但仍保持缓坡（最多 2.5 倍），不出现突然的转速跳水。
    slack = max(0.0, (p["target"] - temp - 3.0) / 5.0)
    rate_down = p["down"] * (1.0 + min(1.5, slack))
    raw_delta = cmd - state["rpm"]
    delta = max(-rate_down, min(rate_up, raw_delta))
    if raw_delta != delta:
        state["integ"] -= 0.06 * (raw_delta - delta)
    state["rpm"] += delta

    # 交还系统：温度足够低、且已降到最低档（避免高转速时误判交还造成温度反弹）
    if temp < p["target"] - 9.0 and state["rpm"] <= fan_min + 100:
        state["cool"] += 1
        if state["cool"] >= RELEASE_HOLD:
            set_auto("(temp=%.1f stable)" % temp)
            write_status("auto")
            return
    else:
        state["cool"] = 0

    if abs(state["rpm"] - state["written"]) >= WRITE_BAND:
        write_rpm(state["rpm"])
        log("temp=%.1f w=%.0f ff=%d(d%.2f) integ=%+d rpm=%d" %
            (temp, state["w_ff"], ff, demand, state["integ"], state["rpm"]))
    write_status("manual")


# ---------------------------------------------------------------- 生命周期

def start_macmon():
    global macmon_proc
    macmon_proc = subprocess.Popen([MACMON, "pipe", "-i", "3000"],
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                   text=True)


def stop_macmon():
    global macmon_proc
    if macmon_proc:
        macmon_proc.kill()
        macmon_proc = None


def bail(signum, frame):
    stop_macmon()
    save_model(force=True)
    set_auto("(signal %d)" % signum)
    log("fanctld stopped by signal %d" % signum)
    sys.exit(0)


def preflight():
    """启动自检：可执行体归属校验 + 风扇探测 + 硬件状态对账。"""
    for path in (SMCFAN, MACMON):
        problem = verify_executable(path)
        if problem:
            log("FATAL preflight: %s" % problem)
            state["err"] = problem
            write_status("error")
            return False
    if not probe_fans():
        r = smcfan("probe")
        if r and "fans=" in (r.stdout or "") and "actual=0" in r.stdout:
            log("SMC appears wedged at startup — waiting 45s for it to recover")
            time.sleep(45)
            probe_fans()
    if state["fans"] <= 0:
        log("FATAL: no controllable fans on this machine")
        state["err"] = "no controllable fans"
        write_status("error")
        return False
    # 对账：无论上个实例留下什么状态，先把硬件交还系统，从干净起点开始
    smcfan("auto")
    state.update(manual=False, rpm=0.0, written=0.0)
    log("preflight ok: fans=%d range=%d~%d rpm" %
        (state["fans"], state["fan_min"], state["fan_max"]))
    return True


def main():
    signal.signal(signal.SIGTERM, bail)
    signal.signal(signal.SIGINT, bail)
    state["machine"] = machine_id()
    state["tm"] = tm_init()
    load_model()
    if not preflight():
        time.sleep(60)                   # 让 launchd 的 KeepAlive 慢速重试而非狂刷
        sys.exit(1)
    log("fanctld started (profile=%s target=%.0f)" % (state["profile"], prof()["target"]))
    try:
        while True:
            if not on_ac_power():
                stop_macmon()
                if state["manual"]:
                    set_auto("(on battery)")
                state["override"] = None
                handle_command()         # 电池期间也消费命令，避免插电瞬间批量生效
                write_status("battery")
                time.sleep(BATT_POLL)
                continue
            if macmon_proc is None or macmon_proc.poll() is not None:
                start_macmon()
            line = macmon_proc.stdout.readline()
            if not line:
                stop_macmon()
                time.sleep(3)
                continue
            try:
                temp = json.loads(line)["temp"]["cpu_temp_avg"]
            except (ValueError, KeyError):
                continue
            if temp and temp > 1:
                try:
                    control_tick(temp)
                    state["tick_errors"] = 0
                except Exception as e:          # 单拍异常不应导致风扇失控
                    state["tick_errors"] = state.get("tick_errors", 0) + 1
                    log("control_tick error (%d): %r" % (state["tick_errors"], e))
                    if state["tick_errors"] >= 20:
                        log("too many consecutive errors — exiting for launchd restart")
                        raise
    finally:
        stop_macmon()
        save_model(force=True)
        set_auto("(daemon exit)")
        log("fanctld stopped")


if __name__ == "__main__":
    main()
