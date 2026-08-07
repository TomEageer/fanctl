# fanctl

Apple Silicon Mac 智能风扇温控套件 — 功耗前馈 + PI 反馈 + 温柔调速。
Smart fan control for Apple Silicon Macs — power feedforward + PI feedback + gentle slew-rate limiting.

macOS 默认的风扇曲线以静音优先，90°C 之前风扇几乎不使劲，机身常年温热。fanctl 把控温目标交还给你：默认把 CPU die 压在 **50°C** 附近，插电时机身摸起来接近常温。

## 特性

- **功耗前馈**：整机功耗（≈发热量）实时映射基准转速——负载一来风扇先动身，不等温度爬升
- **PI 自学习**：积分项自动收敛到"刚好压住当前发热量"的平衡转速，稳定不来回抖
- **温柔调速**：转速每 3 秒最多变 200 rpm，升降都是缓坡，听不到突兀的呼啸起步
- **离电不介入**：电池供电自动交还系统并停止采样，续航零损耗
- **失效保护**：守护进程退出/崩溃/被杀，先恢复系统自动控制再走；转速永远钳在硬件许可区间
- **低成本菜单栏**：15 秒才刷新一次、文本不变不重绘（对 Liquid Glass 渲染友好）、读状态文件不碰 SMC

## 组成

| 组件 | 语言 | 职责 |
|---|---|---|
| `smcfan` | C | AppleSMC 风扇寄存器读写（探测/定速/交还自动） |
| `fanctld` | Python | 温控守护进程（root，LaunchDaemon） |
| `Fanctl.app` | Swift | 菜单栏：显示温度，下拉看转速/功耗/模式，可暂停/恢复/拉满 |
| `fanctl` | Bash | 命令行入口 |

进程间通过两个文件通信：`/tmp/fanctl-status.json`（守护进程每拍写出状态）与 `/tmp/fanctl-cmd`（动词白名单指令：`pause` / `resume` / `max`）。

## 依赖

- Apple Silicon Mac（在 M4 Pro / macOS 26+ 上开发验证；风扇键位 `F%dMd`/`F%dTg` 为 M 系通用）
- Xcode Command Line Tools（编译 C 与 Swift）
- [macmon](https://github.com/vladkens/macmon)（温度传感器读取）：`brew install macmon`

## 安装

```bash
make
sudo ./install.sh   # 或 make install
```

装完守护进程即启动并开机自启，菜单栏出现温度数字。卸载：`sudo ./uninstall.sh`（会先把风扇交还系统）。

## 使用

菜单栏点温度数字：看温度/转速/功耗/模式，或一键 暂停 / 恢复 / 拉满。

```bash
fanctl status    # 状态一览
fanctl pause     # 暂停温控（交还系统）
fanctl resume    # 恢复智能温控
fanctl max       # 风扇拉满
fanctl log       # 最近日志
fanctl stop/start
```

## 调参

旋钮都在 `daemon/fanctld.py` 顶部：

```python
TARGET_TEMP  = 50.0   # 控温目标（想更凉快就调低，想更安静就调高）
ENGAGE_TEMP  = 48.0   # 超过此温度接管
RELEASE_TEMP = 43.0   # 低于此温度稳定 ~72s 后交还系统
KP / KI               # PI 增益
RATE_LIMIT   = 200.0  # 每拍最大转速变化（越小越温柔）
```

改完 `sudo ./install.sh` 重装生效。

**物理预期管理**：风冷笔记本的散热阻力决定了——轻载（<20W）可稳在 45~52°C；持续重载（编译/推理）风扇顶格也只能压到 55~65°C，这不是软件能改变的。

## 安全设计

- 任何退出路径（信号/异常/卸载）都先执行 `smcfan auto` 交还系统
- 目标转速始终钳在 SMC 报告的 `F%dMn`~`F%dMx` 硬件区间内
- 芯片自身的硬件过热保护（降频/强制风扇）优先级高于一切软件，fanctl 无法也不会绕过它
- 指令文件只接受白名单动词；注意 `/tmp/fanctl-cmd` 本机任意用户可写（动词均无害，介意可改路径收紧权限）

## 已知问题

- **不要与 Macs Fan Control / TG Pro 等其他风扇软件同时运行**——两个控制器互相覆写指令，可能把 SMC 接口顶进临时保护状态（读数变 0、写入报 -126；停止争抢后自行恢复，重启必恢复）
- 守护进程运行时，旁路直接 `smcfan probe` 可能读到 0（SMC 通道并发限制），以 `fanctl status`（读状态文件）为准
- 菜单栏应用为 ad-hoc 签名，首次由他处下载运行需右键打开

## License

MIT
