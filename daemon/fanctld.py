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

# 调速性格：quiet 有噪音天花板 / balanced 压住上升徐徐落温 / cool 尽快压下再回落保持
PROFILES = {
    "quiet":    dict(target=58.0, kp=45.0,  ki=4.0, kd=200.0, up=(100.0, 200.0, 350.0),
                     down=100.0, spike=25.0, ff_scale=0.70, cap_frac=0.75),
    "balanced": dict(target=55.0, kp=70.0,  ki=6.0, kd=300.0, up=(150.0, 300.0, 500.0),
                     down=120.0, spike=45.0, ff_scale=1.00, cap_frac=1.00),
    "cool":     dict(target=48.0, kp=130.0, ki=8.0, kd=450.0, up=(300.0, 500.0, 800.0),
                     down=150.0, spike=60.0, ff_scale=1.25, cap_frac=1.00),
}

state = {
    "manual": False, "rpm": 0.0, "written": 0.0, "integ": 0.0, "cool": 0,
    "override": None, "temp": 0.0, "power": 0.0, "act": 0, "err": None,
    "w_slow": 0.0, "w_ff": 0.0, "temps": [], "trend": 0.0, "last_temp": None,
    "profile": "balanced", "gains": {}, "model_dirty": False, "model_saved": 0.0,
    "fan_min": FAN_MIN_DEFAULT, "fan_max": FAN_MAX_DEFAULT, "fans": 0,
    "ticks": 0, "hist_n": 0, "watts_good": None,
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


def write_rpm(rpm):
    r = smcfan("set", str(int(rpm)))
    if r and r.returncode == 0:
        state["written"] = rpm
        state["manual"] = True
        state["err"] = None
        return True
    state["err"] = "fan write failed"
    log("write_rpm failed at %d rpm" % rpm)
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


# ---------------------------------------------------------------- 模型持久化

def prof():
    return PROFILES[state["profile"]]


def ff_gain():
    return state["gains"].get(state["profile"], FF_GAIN_DEFAULT)


def load_model():
    try:
        with open(MODEL) as f:
            m = json.load(f)
    except (OSError, ValueError):
        return
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
            "profile": state["profile"], "updated": now}))
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
            "rpm": int(state["rpm"] if state["manual"] else 0),
            "act": state["act"],
            "profile": state["profile"],
            "fanMin": int(state["fan_min"]), "fanMax": int(state["fan_max"]),
            "fans": state["fans"], "err": state["err"],
            "ts": time.time(),
        }
        write_file_safe(STATUS + ".tmp", json.dumps(payload))
        os.replace(STATUS + ".tmp", STATUS)
    except OSError:
        pass


def append_history(mode):
    if mode == "battery":
        return
    try:
        append_file_safe(HISTORY, json.dumps({
            "ts": round(time.time(), 1), "temp": round(state["temp"], 1),
            "rpm": state["act"], "w": round(state["power"], 1),
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

    # 稳态自学习：把积分携带的常差按当前性格迁进前馈增益（精确回代，保持指令连续）
    state["temps"] = (state["temps"] + [temp])[-8:]
    if (len(state["temps"]) == 8 and max(state["temps"]) - min(state["temps"]) < 0.8
            and fan_min + 60 < state["rpm"] < fan_max - 60 and state["w_ff"] > 10):
        base = max(state["w_ff"] - 8.0, 2.0)
        old = ff_gain()
        new = max(FF_GAIN_MIN, min(FF_GAIN_MAX, old + LEARN_RATE * state["integ"] / base))
        if abs(new - old) > 0.005:
            state["gains"][state["profile"]] = new
            state["integ"] -= base * (new - old) * p["ff_scale"]
            state["model_dirty"] = True
    save_model()

    ff = fan_min + max(0.0, state["w_ff"] - 8.0) * ff_gain() * p["ff_scale"]
    cmd_raw = ff + spike + damp + p["kp"] * err + state["integ"]

    # 抗饱和反算：输出钳位与斜率限幅都是饱和环节，两者都要泄积分
    ceil = fan_min + (fan_max - fan_min) * p["cap_frac"]
    if cmd_raw > ceil:
        state["integ"] -= 0.06 * (cmd_raw - ceil)
    elif cmd_raw < fan_min:
        state["integ"] += 0.06 * (fan_min - cmd_raw)
    cmd = max(fan_min, min(ceil, cmd_raw))

    rate_up = p["up"][2] if err > 15 else p["up"][1] if err > 5 else p["up"][0]
    raw_delta = cmd - state["rpm"]
    delta = max(-p["down"], min(rate_up, raw_delta))
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
        log("temp=%.1f w=%.0f ff=%d integ=%+d rpm=%d" %
            (temp, state["w_ff"], ff, state["integ"], state["rpm"]))
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
                control_tick(temp)
    finally:
        stop_macmon()
        save_model(force=True)
        set_auto("(daemon exit)")
        log("fanctld stopped")


if __name__ == "__main__":
    main()
