#!/usr/bin/env python3
"""
fanctld — Apple Silicon smart fan control daemon (feedforward + PI + slew-rate limit)
智能风扇温控守护进程：功耗前馈 + PI 反馈 + 斜率限制。

Control strategy 控制策略:
  Feedforward 前馈: whole-system power draw (≈ heat output, from battery telemetry)
    maps to a baseline RPM — fans react to load changes before temperature moves.
  PI feedback 反馈: proportional + integral on (temp - target); the integral term
    auto-learns the equilibrium RPM for the current load & ambient.
  Slew-rate limit 斜率限制: RPM changes at most RATE_LIMIT per tick (~3s) — gentle.
  On battery 离电: releases control and stops sampling. On exit 退出: always
    restores system-auto fan mode.

IPC:
  /tmp/fanctl-status.json  — written every tick (temp/rpm/mode/power), for the menu bar app
  /tmp/fanctl-cmd          — verb file: pause | resume | max (whitelist only)
"""
import json
import os
import re
import signal
import subprocess
import sys
import time

MACMON = next((p for p in ("/opt/homebrew/bin/macmon",
                            "/usr/local/bin/fanctl-macmon") if os.path.exists(p)),
              "/opt/homebrew/bin/macmon")
SMCFAN  = "/usr/local/bin/smcfan"
LOG     = "/var/log/fanctl.log"
STATUS  = "/tmp/fanctl-status.json"
CMD     = "/tmp/fanctl-cmd"
HISTORY = "/tmp/fanctl-history.jsonl"
MODEL   = "/usr/local/var/fanctl/model.json"   # 自学习热模型（持久化）
HIST_KEEP = 2400          # 修剪后保留的样本数（约 2 小时 @3s）
HIST_TRIM_AT = 4800       # 超过此行数触发修剪

FAN_MIN      = 2317.0
FAN_MAX      = 7826.0
KI           = 6.0    # 积分：缓慢把温度带回目标，三档共用

# 调速性格三档：quiet 尽可能慢慢压 / balanced 压住上升徐徐落温 / cool 尽快压下再回落保持
PROFILES = {
    "quiet":    dict(target=58.0, kp=45.0,  kd=200.0, up=(100.0, 200.0, 350.0), down=100.0, spike=25.0),
    "balanced": dict(target=55.0, kp=70.0,  kd=300.0, up=(150.0, 300.0, 500.0), down=120.0, spike=45.0),
    "cool":     dict(target=48.0, kp=130.0, kd=450.0, up=(300.0, 500.0, 800.0), down=150.0, spike=60.0),
}


def prof():
    return PROFILES[state.get("profile", "balanced")]
WRITE_BAND   = 75.0
POWER_HOLD   = 60.0    # 功耗读数失效时沿用上一有效值的时长（秒）
FF_GAIN_MIN  = 60.0    # 自学习前馈增益下限（RPM/W）
FF_GAIN_MAX  = 200.0   # 上限
LEARN_RATE   = 0.02    # 稳态时积分向前馈增益的迁移速率
RELEASE_HOLD = 24
BATT_POLL    = 30

state = {"manual": False, "rpm": 0.0, "written": 0.0, "integ": 0.0, "cool": 0,
         "override": None, "temp": 0.0, "power": 0.0,
         "ff_gain": 110.0, "w_slow": 0.0, "temps": [], "model_dirty": False,
         "model_saved": 0.0, "profile": "balanced"}


def load_model():
    try:
        with open(MODEL) as f:
            m = json.load(f)
        state["ff_gain"] = max(FF_GAIN_MIN, min(FF_GAIN_MAX, float(m.get("ff_gain", 110.0))))
        if m.get("profile") in PROFILES:
            state["profile"] = m["profile"]
        log("model loaded: ff_gain=%.1f rpm/W" % state["ff_gain"])
    except (OSError, ValueError):
        pass


def save_model(force=False):
    now = time.time()
    if not force and (not state["model_dirty"] or now - state["model_saved"] < 300):
        return
    try:
        os.makedirs(os.path.dirname(MODEL), exist_ok=True)
        with open(MODEL, "w") as f:
            json.dump({"ff_gain": round(state["ff_gain"], 2), "profile": state["profile"], "updated": now}, f)
        state["model_dirty"] = False
        state["model_saved"] = now
    except OSError:
        pass
macmon_proc = None


def log(msg):
    try:
        if os.path.exists(LOG) and os.path.getsize(LOG) > 1 << 20:
            os.truncate(LOG, 0)
        with open(LOG, "a") as f:
            f.write("%s %s\n" % (time.strftime("%F %T"), msg))
    except OSError:
        pass


def smcfan(*args):
    try:
        return subprocess.run([SMCFAN, *args], capture_output=True, text=True, timeout=10)
    except Exception as e:
        log("smcfan error: %s" % e)
        return None


def read_actual_rpm():
    r = smcfan("get", "F0Ac")
    if r and r.returncode == 0:
        m = re.search(r"value=([0-9.]+)", r.stdout)
        if m:
            return max(float(m.group(1)), FAN_MIN)
    return FAN_MIN


def read_actual_raw():
    """实际转速原始读数，读不到返回 0（用于状态展示与历史记录）。"""
    r = smcfan("get", "F0Ac")
    if r and r.returncode == 0:
        m = re.search(r"value=([0-9.]+)", r.stdout)
        if m:
            return int(float(m.group(1)))
    return 0


def read_power_watts():
    try:
        out = subprocess.run(["ioreg", "-rn", "AppleSmartBattery"],
                             capture_output=True, text=True, timeout=10).stdout
        m = re.search(r'"SystemPowerIn"=(\d+)', out)
        if m and int(m.group(1)) > 0:
            state["watts_good"] = (int(m.group(1)) / 1000.0, time.time())
            return state["watts_good"][0]
    except Exception:
        pass
    # 电源遥测间歇性读 0/失败：短时间内沿用上一有效值，防止前馈塌缩
    held = state.get("watts_good")
    if held and time.time() - held[1] < POWER_HOLD:
        return held[0]
    return None


def feedforward_rpm(watts):
    if watts is None:
        return FAN_MIN
    return min(FAN_MAX, FAN_MIN + max(0.0, watts - 8.0) * state["ff_gain"])


def write_status(mode):
    append_history(mode)
    try:
        tmp = STATUS + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"temp": round(state["temp"], 1),
                       "rpm": int(state["rpm"] if state["manual"] else 0),
                       "mode": mode,
                       "act": state.get("act", 0),
                       "profile": state.get("profile", "balanced"),
                       "power": round(state["power"], 1),
                       "ts": time.time()}, f)
        os.replace(tmp, STATUS)
        os.chmod(STATUS, 0o644)
    except OSError:
        pass


def append_history(mode):
    """按控制节拍追加历史样本；文件超限时修剪为最近 HIST_KEEP 条。"""
    try:
        with open(HISTORY, "a") as f:
            f.write(json.dumps({"ts": round(time.time(), 1),
                                "temp": round(state["temp"], 1),
                                "rpm": state.get("act", 0),
                                "mode": mode,
                                "pf": state.get("profile", "balanced")}) + "\n")
        os.chmod(HISTORY, 0o644)
        state["hist_n"] = state.get("hist_n", 0) + 1
        if state["hist_n"] >= 400:
            state["hist_n"] = 0
            with open(HISTORY) as f:
                lines = f.readlines()
            if len(lines) > HIST_TRIM_AT:
                with open(HISTORY, "w") as f:
                    f.writelines(lines[-HIST_KEEP:])
    except OSError:
        pass


def read_command():
    """消费指令文件，只接受白名单动词（文件对普通用户可写，动词之外一律忽略）。
    合法: pause | resume | max | set <rpm>"""
    try:
        with open(CMD) as f:
            verb = f.read().strip()
        os.unlink(CMD)
    except OSError:
        return None
    if verb in ("pause", "resume", "max"):
        return verb
    if verb.startswith("profile ") and verb.split()[1] in PROFILES:
        return verb
    m = re.match(r"^set (\d{3,5})$", verb)
    if m:
        return "set " + m.group(1)
    return None


def set_auto(reason=""):
    smcfan("auto")
    if state["manual"]:
        log("released to system auto %s" % reason)
    state.update(manual=False, rpm=0.0, written=0.0, integ=0.0, cool=0)


def write_rpm(rpm):
    r = smcfan("set", str(int(rpm)))
    if r and r.returncode == 0:
        state["written"] = rpm
        state["manual"] = True


def on_ac_power():
    try:
        out = subprocess.run(["pmset", "-g", "batt"], capture_output=True, text=True, timeout=10).stdout
        return "AC Power" in out
    except Exception:
        return True


def start_macmon():
    global macmon_proc
    macmon_proc = subprocess.Popen([MACMON, "pipe", "-i", "3000"],
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)


def stop_macmon():
    global macmon_proc
    if macmon_proc:
        macmon_proc.kill()
        macmon_proc = None


def bail(signum, frame):
    stop_macmon()
    set_auto("(daemon exit)")
    log("fanctld stopped by signal %d" % signum)
    sys.exit(0)


def handle_command():
    verb = read_command()
    if verb is None:
        return
    if verb == "pause":
        state["override"] = "pause"
        set_auto("(paused by user)")
    elif verb == "resume":
        state["override"] = None
        log("user override cleared, smart control resumed")
    elif verb.startswith("profile "):
        state["profile"] = verb.split()[1]
        state["override"] = None          # 选性格即进入智能调速，解除暂停/手动
        state["model_dirty"] = True
        save_model(force=True)
        log("profile -> %s (smart control active)" % state["profile"])
    else:                                   # max 或 set <rpm> → 自定义定速模式
        rpm = FAN_MAX if verb == "max" else float(verb.split()[1])
        rpm = max(FAN_MIN, min(FAN_MAX, rpm))
        state["override"] = "custom"
        state["rpm"] = rpm
        write_rpm(rpm)
        log("user override: custom %d rpm" % rpm)


def control_tick(temp):
    state["temp"] = temp
    watts = read_power_watts()
    state["power"] = watts or 0.0
    state["act"] = read_actual_raw()

    handle_command()
    if state["override"] == "pause":
        write_status("paused")
        return
    if state["override"] == "custom":
        if abs(state["written"] - state["rpm"]) >= 1:   # 断言定速仍然生效
            write_rpm(state["rpm"])
        write_status("custom")
        return

    if not state["manual"]:
        if temp >= prof()["target"] - 2.0:
            state["rpm"] = read_actual_rpm()
            state["integ"] = 0.0
            state["cool"] = 0
            write_rpm(state["rpm"])
            log("temp=%.1f engage from %d rpm (gentle ramp)" % (temp, state["rpm"]))
        write_status("manual" if state["manual"] else "auto")
        return

    err = temp - prof()["target"]
    state["integ"] = max(-1500.0, min(FAN_MAX - FAN_MIN, state["integ"] + KI * err))

    # 趋势阻尼：只针对"温度正在上升"发力，升势一被摁住即退出（不参与压绝对温度）
    d = temp - state.get("last_temp", temp)
    state["last_temp"] = temp
    state["trend"] = state.get("trend", 0.0) * 0.5 + d * 0.5
    damp = prof()["kd"] * max(0.0, state["trend"])

    # 功耗突增预压制：功耗快线越过慢线的瞬间提前提转速，不等温度上来
    w = watts or 0.0
    if state["w_slow"] <= 0:
        state["w_slow"] = w
    dw = w - state["w_slow"]
    spike = min(1000.0, max(0.0, dw - 3.0) * prof()["spike"]) if dw > 3.0 else 0.0
    state["w_slow"] = state["w_slow"] * 0.90 + w * 0.10

    # 稳态自学习：温度平稳且输出未贴边时，积分携带的常差缓慢迁入前馈增益，
    # 让"功耗→所需转速"的映射长期贴合本机散热效率（学习结果持久化）
    state["temps"] = (state["temps"] + [temp])[-8:]
    if (len(state["temps"]) == 8 and max(state["temps"]) - min(state["temps"]) < 0.8
            and FAN_MIN + 60 < state["rpm"] < FAN_MAX - 60 and w > 10):
        corr = state["integ"] / max(w - 8.0, 2.0)
        new_gain = max(FF_GAIN_MIN, min(FF_GAIN_MAX, state["ff_gain"] + LEARN_RATE * corr))
        if abs(new_gain - state["ff_gain"]) > 0.005:
            state["ff_gain"] = new_gain
            state["integ"] *= 0.985
            state["model_dirty"] = True
    save_model()

    cmd_raw = feedforward_rpm(watts) + spike + damp + prof()["kp"] * err + state["integ"]
    # 抗饱和反算（anti-windup back-calculation）：
    # 指令越过硬件上下限时，把积分往回拉到贴着边界，避免"历史欠账"锁死输出
    if cmd_raw > FAN_MAX:
        state["integ"] -= 0.06 * (cmd_raw - FAN_MAX)
    elif cmd_raw < FAN_MIN:
        state["integ"] += 0.06 * (FAN_MIN - cmd_raw)
    cmd = max(FAN_MIN, min(FAN_MAX, cmd_raw))
    up = prof()["up"]
    rate_up = up[2] if err > 15 else up[1] if err > 5 else up[0]
    delta = max(-prof()["down"], min(rate_up, cmd - state["rpm"]))
    state["rpm"] += delta

    if temp < prof()["target"] - 9.0:
        state["cool"] += 1
        if state["cool"] >= RELEASE_HOLD:
            set_auto("(temp=%.1f stable cool)" % temp)
            write_status("auto")
            return
    else:
        state["cool"] = 0

    if abs(state["rpm"] - state["written"]) >= WRITE_BAND:
        write_rpm(state["rpm"])
        log("temp=%.1f ff=%d integ=%+d rpm=%d" % (temp, feedforward_rpm(watts), state["integ"], state["rpm"]))
    write_status("manual")


def main():
    signal.signal(signal.SIGTERM, bail)
    signal.signal(signal.SIGINT, bail)
    load_model()
    log("fanctld started (profile=%s target=%s)" % (state["profile"], prof()["target"]))
    try:
        while True:
            if not on_ac_power():
                stop_macmon()
                if state["manual"]:
                    set_auto("(on battery)")
                state["override"] = None
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
            control_tick(temp)
    finally:
        stop_macmon()
        save_model(force=True)
        set_auto("(daemon exit)")
        log("fanctld stopped")


if __name__ == "__main__":
    main()
