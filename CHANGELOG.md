# Changelog · 更新日志

All notable changes, grouped by major version. Detailed per-release notes live on the
[Releases page](https://github.com/TomEageer/fanctl/releases); every version remains
available as a git tag.

按大版本归纳的更新记录。单版详情见 [Releases 页面](https://github.com/TomEageer/fanctl/releases)，所有版本的 git tag 均保留。

---

## 2.5 — Units & honest diagnostics · 单位与诚实的诊断

**EN**
- Celsius / Fahrenheit follows the system preference (2.5.0).
- **Stale first frame fix** (2.5.2): opening the menu "suddenly" showed the history chart squeezed left with a blank right edge for a few seconds — `menuWillOpen` triggered a reload while the menu window was not yet visible, so the visibility guard silently swallowed it and the first frame drew the previous session's cache (switching the time window "fixed" it because that path forces a redraw). Explicit refresh points now bypass the guard. The README gains a real-data load-response chart (from the daemon's own 3-second telemetry, light/dark aware) and a downloads badge.
- **Accurate takeover notice** (2.5.1): the warning shown when the SMC holds fan control claimed it "usually happens after wake" — log correlation against `pmset -g log` disproved that (takeovers occurred with no sleep for two days, at 52–55 °C, while manual control succeeded at the same temperatures minutes later). The real trigger is rapid `F0Md` mode-key flips, e.g. reinstalling the background service several times in a row. The notice is now short, cause-neutral, and no longer stretches the menu; the daemon logs the actual `F0Md` value on every rejection for future forensics.

**中文**
- 摄氏 / 华氏跟随系统偏好（2.5.0）。
- **图表首帧陈旧修复**（2.5.2）：菜单"突然打开"的头几秒，历史曲线挤在左侧、右侧空一截——根因是 `menuWillOpen` 触发刷新时菜单窗口尚未可见，被 reload 的可见性守卫静默吞掉，首帧画的是上一次打开的旧缓存（切换时间窗因走 forceRedraw 而"恢复"）。显式刷新点改为绕过守卫。README 新增满负载实测响应图（daemon 3 秒遥测真实数据、深浅色自适应）与下载量徽章。
- **接管提示修正**（2.5.1）：SMC 收回风扇控制时的警告原写着"通常发生在唤醒后"——与 `pmset -g log` 对照证伪（整机两天未睡眠、52–55°C 时段照样接管，且几分钟后同温度手动控制成功）。真实触发是 `F0Md` 模式键短时高频翻转（如连续多次重装后台服务）。提示改为简短、不预设归因的文案，不再撑宽菜单；daemon 在每次写入被拒时记录 `F0Md` 实际值，便于后续取证。

## 2.4 — Support & footprint · 赞赏与资源占用

**EN**
- In-app Support window (Alipay / WeChat QR, one-click-copy crypto addresses, external links), driven by a bundled `donate.json` so unconfigured entries stay hidden.
- Bilingual `DONATE.md`, GitHub Sponsor button config, README badges quoting **measured** footprint numbers.
- **Menu CPU 33.2 % → 2.5 %**: profiling showed all CPU inside AppKit's vImage blur — reassigning identical menu text still dirties the item and forces macOS to re-blur the whole translucent backdrop. All UI text now goes through change-detecting setters; the chart skips redraws without new samples; history parsing became incremental; timers are invalidated before re-creation and gated on window visibility.

**中文**
- 应用内「赞赏支持」窗口（支付宝/微信二维码、加密货币地址一键复制、外部链接），内容由随包的 `donate.json` 驱动，未配置的条目自动隐藏。
- 双语 `DONATE.md`、GitHub 赞助按钮配置、README 实测徽章。
- **菜单 CPU 33.2% → 2.5%**：剖析发现 CPU 全在 AppKit 的 vImage 模糊上——重写内容相同的菜单文字仍会标脏，逼使 macOS 重算整块毛玻璃背景。现在所有界面文本走「不变不写」；图表无新样本不重绘；历史改增量解析；定时器创建前必销毁并按可见性门禁。

## 2.3 — Reliability under real-world conditions · 真实环境下的可靠性

**EN**
- **Root cause of recurring SMC lockouts**: the fan *mode* key accepts only 0/1 and was being rewritten on every speed update (~20×/min). Hammering it puts the SMC into a system-owned override state (`F0Md` reads 3) that rejects all writes. The mode key is now read before writing and changed only when necessary; target RPM continues to be written freely.
- Monitoring decoupled from control: when fan control is unavailable, temperature and power keep being recorded and the temperature curve stays continuous — only the RPM/cooling series breaks.
- A zero RPM reading no longer counts as a failure (fans legitimately stop); only rejected writes do.
- Errors surface as localized, actionable text instead of internal backoff messages.
- Feedforward gated by temperature margin: whole-system watts include display, peripherals and charging losses that never reach the heatsink, so power alone was over-driving the fans. Spin-down also widens as thermal headroom grows.

**中文**
- **查明 SMC 反复被锁的根因**：风扇模式键只接受 0/1，而此前每次设定转速都会重写它（约每分钟 20 次）。高频重写会把 SMC 顶进系统接管状态（`F0Md` 读出 3），此后所有写入被拒。现在模式键先读后写、仅在必要时改动；目标转速键照常高频写。
- 监控与控制解耦：风扇控制不可用时，温度与功耗照常记录，温度曲线保持连续，仅转速/散热曲线断口。
- 转速读到 0 不再判定为故障（风扇本就可能停转），只有写入被拒才算。
- 错误以可操作的本地化文案呈现，取代内部退避信息。
- 前馈受温度裕度调制：整机功耗含屏幕、外设与充电损耗，并不进散热片，纯按瓦数拉转速会过冲；降速斜率随温度富余放宽。

## 2.2 — Per-machine thermal model · 按机型学习的热模型

**EN**
- Machine-keyed priors (`hw.model`) ship as defaults and are refined per machine by weakly-weighted regression: new installs are useful within a minute and converge to the actual chassis over time; a machine change discards the learned model.
- Heat capacity fixed at the machine prior instead of fitted — it is not identifiable from noisy closed-loop derivatives, and free fitting produced non-physical negative values that blocked convergence.
- SMC exponential backoff; launchd throttle raised; startup probe retries before declaring "no fans".
- No placeholder zeros: samples without a valid reading are not recorded and curves break across gaps.
- Centripetal Catmull-Rom spline replaces uniform parameterization, which overshot and self-intersected at near-vertical transitions.

**中文**
- 按 `hw.model` 匹配出厂先验作为默认值，再以弱先验权重按机器实测修正：新机第一分钟即可用，用得越久越贴合本机；换机器自动丢弃重学。
- 热容改为取机型先验而非自由拟合——闭环噪声导数下它不可辨识，自由求解会得到非物理负值并卡死收敛。
- SMC 指数退避；launchd 重启节流提高；启动探测失败先重试再判定「无风扇」。
- 不再用 0 冒充数据：无有效读数不记录，曲线在缺口处断开。
- 曲线改用向心参数化 Catmull-Rom，修复近垂直跳变处过冲自交（曲线「向后回勾」）。

## 2.1 — Physical thermal model · 物理热模型

**EN**
- Replaced the arbitrary power axis with an identified physical model: at steady state `W = h(rpm)·(T_die − T_amb)`, where `h(rpm) = k0 + k1·(rpm/1000)` [W/°C] is a fixed property of the machine. The daemon accumulates sufficient statistics with a forgetting factor and solves for the coefficients and ambient temperature.
- The chart plots heat produced against heat removed on a shared watt axis: the solid line above the dashed one literally means the machine is cooling down.

**中文**
- 用辨识出的物理模型取代此前假定的功耗刻度：稳态下 `产热 = h(转速) × (芯片温度 − 环境温度)`，其中 `h(转速) = k0 + k1·(转速/1000)`（W/°C）是本机固有属性。守护进程以带遗忘因子的充分统计量在线累积并求解系数与环境温度。
- 图表改为产热量与散热量同轴对比：实线在虚线之上即表示正在降温。

## 2.0 — Security hardening & fail-safe · 安全加固与失效保护

**EN**
- Executables moved to a root-owned directory and ownership-verified before every run (`/usr/local/bin` is user-writable on Homebrew systems — a root daemon executing from there was a local privilege-escalation surface).
- Runtime files moved off `/tmp`; the command channel became a `root:admin 0770` directory; all daemon writes use `O_NOFOLLOW`.
- Boot-time restore daemon returns fan control to macOS at every startup, covering SIGKILL / panic / power loss; the daemon reconciles hardware state during preflight.
- Uninstaller ships inside the app with a menu entry — GUI installs were previously impossible to fully remove.
- Fan range probed per machine instead of hardcoded; per-profile learned gains; battery mode reports null instead of frozen values.
- Update progress window gained a Cancel button; the silent daily check no longer steals focus; a leaked `URLSession` was fixed.

**中文**
- 可执行体迁至 root 独占目录并在每次运行前校验归属（Homebrew 系统上 `/usr/local/bin` 用户可写，root 守护从中执行构成本地提权面）。
- 运行时文件迁出 `/tmp`；命令通道改为 `root:admin 0770` 目录；守护进程所有写入使用 `O_NOFOLLOW`。
- 新增开机恢复服务，每次开机把风扇交还系统，覆盖 SIGKILL / 内核崩溃 / 断电；守护启动时与硬件状态对账。
- 卸载器随 App 分发并提供菜单入口——此前 GUI 安装的用户无法完整卸载。
- 风扇量程按机型探测；每档性格独立学习增益；电池模式回报空值而非冻结的旧数据。
- 更新进度窗增加取消按钮；每日静默检查不再抢焦点；修复 `URLSession` 泄漏。

## 1.x — From first control loop to a shipping app · 从控制回路到成品应用

**EN**
- Control: power feedforward + PI with back-calculation anti-windup, trend damping, power-spike preemption, asymmetric slew limiting, and three selectable profiles (Quiet / Balanced / Cool) with a real noise ceiling on Quiet.
- Interface: menu bar temperature (later two rows with power), temperature/RPM history chart with mode-coloured bands and a time-range selector, dual-dot speed control, standalone control panel, app icon, eight languages with an in-app switcher.
- Distribution: self-contained drag-and-drop app bundling the SMC tool, daemon and sensor reader; one-click privileged install; GitHub Releases auto-update with a progress window; single-instance guard.

**中文**
- 控制：功耗前馈 + 带抗饱和反算的 PI、趋势阻尼、功耗突增预压制、非对称斜率限制，以及三档可选性格（安静 / 均衡 / 凉爽），安静档带真实噪音天花板。
- 界面：菜单栏温度（后为温度+功耗双行）、按模式着色的温度/转速历史曲线与时间窗选择、双点转速控件、独立控制面板、应用图标、八种语言与应用内切换。
- 分发：自包含的拖装即用 App（内含 SMC 工具、守护进程与传感器读取器）、一键授权安装、基于 GitHub Releases 的自动更新与进度窗、单实例守卫。
