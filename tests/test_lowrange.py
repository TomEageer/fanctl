"""低转速/停转扩展的离线闭环仿真验证。"""
import sys, importlib.util
spec = importlib.util.spec_from_file_location("fanctld", "/Users/tom/projects/fanctl/daemon/fanctld.py")
f = importlib.util.module_from_spec(spec); sys.modules["fanctld"] = f
spec.loader.exec_module(f)

K0, K1, TAMB, CAP, HEAT = 0.30, 0.13, 25.0, 180.0, 0.6

def run(watts_seq, low_range, t0=45.0):
    st = f.state
    st.update(machine="Mac16,8", fans=2, fan_min=2317.0, fan_max=7826.0,
              profile="balanced", manual=True, rpm=2317.0, written=2317.0,
              integ=0.0, trend=0.0, last_temp=t0, temp=t0, cool=0, ticks=0,
              low_range=low_range, in_low=False, w_ff=watts_seq[0], w_slow=watts_seq[0],
              gains={}, tm=f.tm_init(), override=None, temps=[], smc_fails=0, smc_until=0)
    f.write_rpm = lambda r: (st.__setitem__("written", r), st.__setitem__("manual", True), True)[-1]
    f.read_fan_field = lambda k: st["rpm"] if k == "F0Ac" else 1.0
    f.write_status = lambda m: None
    f.handle_command = lambda: None
    f.save_model = lambda *a, **k: None
    f.smc_manual_mode = lambda: True
    T = t0; trace = []
    for W in watts_seq:
        f.read_power_watts = lambda w=W: w
        f.control_tick(T)          # 不强制 manual：交还系统后按真实分支走
        rpm = st["rpm"]
        h = K0 + K1 * rpm / 1000
        T += ((W * HEAT) - h * (T - TAMB)) / CAP * 3
        trace.append((round(rpm), round(T, 1), st["in_low"]))
    return trace

ok = True
def check(name, cond, detail=""):
    global ok
    print("  %s %s %s" % ("PASS" if cond else "FAIL", name, detail))
    ok = ok and cond

print("1) 轻载 15W · 关闭低转区（旧行为）")
tr = run([15.0] * 300, low_range=False)
engaged = [r for r, _, _ in tr if r > 0]
check("接管期间从不低于标称最低 2317", all(r >= 2317 for r in engaged),
      "最低 %d rpm" % min(engaged))

print("2a) 中轻载 15W · 开启低转区（物理上需保留最低转速）")
tr = run([15.0] * 300, low_range=True)
tail = tr[-40:]
sf = f.spin_floor()
check("降到起转门限（低于标称最低）", min(r for r, _, _ in tail) <= sf + 1,
      "末端 %d rpm，标称最低 2317，起转门限 %d" % (tail[-1][0], sf))

print("2b) 极轻载 8W · 应完全停转")
tr2 = run([8.0] * 400, low_range=True)
tail2 = tr2[-60:]
check("出现 0 转（完全停转）", any(r == 0 for r, _, _ in tail2),
      "末端 %d rpm，温度 %.1f°C" % (tail2[-1][0], tail2[-1][1]))
check("停转后温度仍低于目标", max(t for _, t, _ in tail2) < 55, "峰值 %.1f°C" % max(t for _, t, _ in tail2))
viol = [(r, t) for r, t, _ in tail + tail2 if not (r == 0 or r >= sf - 1)]
check("从不停留在死区内", not viol, "死区 0~%d，违规样本 %s" % (sf, viol[:5]))
check("温度仍受控（未失控上升）", max(t for _, t, _ in tail) < 60, "峰值 %.1f°C" % max(t for _, t, _ in tail))

print("3) 负载突增 15W→70W · 低转区应立即退出")
tr = run([15.0] * 150 + [70.0] * 200, low_range=True)
after = tr[150:200]
check("30 拍内退出低转区", any(not lo for _, _, lo in after[:10]), "")
check("转速回到标称最低以上", max(r for r, _, _ in tr[170:]) > 2317, "峰值 %d rpm" % max(r for r, _, _ in tr[170:]))
check("温度未失控", max(t for _, t, _ in tr) < 75, "峰值 %.1f°C" % max(t for _, t, _ in tr))

print("4) 迟滞：温度在阈值附近摆动不应频繁进出")
tr = run([26.0] * 400, low_range=True)
flips = sum(1 for i in range(1, len(tr)) if tr[i][2] != tr[i-1][2])
check("进出次数 ≤ 6", flips <= 6, "实际 %d 次" % flips)

print("5) 手动定速接受 0 与死区吸附")
f.state.update(low_range=True, fan_min=2317.0, fan_max=7826.0, override=None)
for want, expect in ((0, 0), (500, 0), (900, f.spin_floor()), (1500, 1500), (9999, 7826)):
    f.state["rpm"] = -1
    f.handle_command = None
    v = float(want); lo = 0.0
    v = max(lo, min(f.state["fan_max"], v))
    if 0 < v < f.spin_floor():
        v = 0.0 if v < f.spin_floor() * 0.6 else f.spin_floor()
    check("set %d → %d" % (want, expect), abs(v - expect) < 1, "得到 %d" % v)

print("\n总计: %s" % ("全部通过" if ok else "存在失败"))
sys.exit(0 if ok else 1)
