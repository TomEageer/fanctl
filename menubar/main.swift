// Fanctl menu bar app
// Low-overhead by design:
//   * menu closed  -> 15s slow refresh, title redraws only on text change
//   * menu open    -> 2s live refresh, chart reloads every 6s
//   * all data read from daemon-written files; never touches SMC directly
// First launch: offers to install the privileged background service bundled in Resources.
import AppKit

let statusPath  = "/tmp/fanctl-status.json"
let historyPath = "/tmp/fanctl-history.jsonl"
let cmdPath     = "/tmp/fanctl-cmd"
let daemonPlist = "/Library/LaunchDaemons/io.fanctl.daemon.plist"
let fanMin = 2317.0
let fanMax = 7826.0
let rpmAxisMax = 8000.0

struct Sample { let ts, temp: Double; let rpm: Double; let mode: String }

func modeColor(_ mode: String) -> NSColor {
    switch mode {
    case "manual":  return .systemBlue     // 智能调速
    case "custom":  return .systemOrange   // 手动定速
    case "battery": return .systemGreen    // 电池供电
    default:        return .systemGray     // 系统调度
    }
}

func modeName(_ mode: String, rpm: Double) -> String {
    switch mode {
    case "manual":  return "智能调速"
    case "auto":    return "智能调速 · 待命"
    case "custom":  return "手动定速 · \(Int(rpm)) RPM"
    case "paused":  return "系统调度"
    case "battery": return "电池供电 · 系统调度"
    default:        return mode
    }
}

// MARK: - 温度/转速历史曲线

final class ChartView: NSView {
    var samples: [Sample] = []
    var windowSec: Double = Double(UserDefaults.standard.integer(forKey: "chartWindow") == 0
                                   ? 1800 : UserDefaults.standard.integer(forKey: "chartWindow"))
    let windowOptions: [(String, Double)] = [("10 分", 600), ("30 分", 1800), ("1 时", 3600), ("2 时", 7200)]
    var segmented: NSSegmentedControl!

    private let padL: CGFloat = 30, padR: CGFloat = 34, padT: CGFloat = 26, padB: CGFloat = 30

    override init(frame: NSRect) {
        super.init(frame: frame)
        segmented = NSSegmentedControl(labels: windowOptions.map { $0.0 },
                                       trackingMode: .selectOne, target: self,
                                       action: #selector(windowChanged(_:)))
        segmented.controlSize = .mini
        segmented.font = .systemFont(ofSize: 9)
        segmented.frame = NSRect(x: frame.width - 150, y: frame.height - 22, width: 144, height: 18)
        segmented.selectedSegment = windowOptions.firstIndex { $0.1 == windowSec } ?? 1
        addSubview(segmented)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc func windowChanged(_ s: NSSegmentedControl) {
        windowSec = windowOptions[s.selectedSegment].1
        UserDefaults.standard.set(Int(windowSec), forKey: "chartWindow")
        reload()
    }

    func reload() {
        guard let raw = try? String(contentsOfFile: historyPath, encoding: .utf8) else {
            samples = []; needsDisplay = true; return
        }
        let cutoff = Date().timeIntervalSince1970 - windowSec
        samples = raw.split(separator: "\n").suffix(4800).compactMap { line in
            guard let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let ts = (o["ts"] as? NSNumber)?.doubleValue, ts >= cutoff,
                  let t  = (o["temp"] as? NSNumber)?.doubleValue, t > 1 else { return nil }
            return Sample(ts: ts, temp: t,
                          rpm: (o["rpm"] as? NSNumber)?.doubleValue ?? 0,
                          mode: o["mode"] as? String ?? "auto")
        }
        samples = smoothed(samples, window: 5)
        needsDisplay = true
    }

    /// 显示层平滑：居中移动平均（原始历史数据不动）
    private func smoothed(_ raw: [Sample], window: Int) -> [Sample] {
        guard raw.count > window else { return raw }
        let half = window / 2
        return raw.enumerated().map { i, s in
            let a = max(0, i - half), b = min(raw.count - 1, i + half)
            let n = Double(b - a + 1)
            let t = raw[a...b].reduce(0.0) { $0 + $1.temp } / n
            let r = raw[a...b].reduce(0.0) { $0 + $1.rpm } / n
            return Sample(ts: s.ts, temp: t, rpm: r, mode: s.mode)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let plot = NSRect(x: padL, y: padB, width: bounds.width - padL - padR,
                          height: bounds.height - padT - padB)
        let title = windowOptions.first { $0.1 == windowSec }?.0 ?? ""
        drawText("温度 / 转速历史 · \(title.replacingOccurrences(of: " ", with: ""))钟",
                 at: NSPoint(x: padL, y: bounds.height - 18), size: 11, color: .labelColor, bold: true)
        drawLegend()

        guard samples.count >= 2 else {
            drawText("正在采集数据…", at: NSPoint(x: plot.midX - 36, y: plot.midY),
                     size: 10, color: .secondaryLabelColor)
            return
        }

        let now = Date().timeIntervalSince1970
        let t0 = now - windowSec
        var lo = floor((samples.map { $0.temp }.min()! - 3) / 5) * 5
        var hi = ceil((samples.map { $0.temp }.max()! + 3) / 5) * 5
        if hi - lo < 15 { hi = lo + 15 }
        lo = max(lo, 20); hi = min(hi, 110)

        func px(_ ts: Double) -> CGFloat { plot.minX + CGFloat((ts - t0) / (now - t0)) * plot.width }
        func pyT(_ v: Double) -> CGFloat { plot.minY + CGFloat((v - lo) / (hi - lo)) * plot.height }
        func pyR(_ v: Double) -> CGFloat { plot.minY + CGFloat(v / rpmAxisMax) * plot.height }

        var i = 0
        while i < samples.count {
            var j = i
            while j + 1 < samples.count && samples[j + 1].mode == samples[i].mode { j += 1 }
            let x1 = px(samples[i].ts), x2 = max(px(samples[j].ts), x1 + 1)
            modeColor(samples[i].mode).withAlphaComponent(0.15).setFill()
            NSRect(x: x1, y: plot.minY, width: x2 - x1, height: plot.height).fill()
            i = j + 1
        }

        NSColor.separatorColor.setStroke()
        for temp in stride(from: lo, through: hi, by: 10) {
            let g = NSBezierPath(); g.lineWidth = 0.5
            g.move(to: NSPoint(x: plot.minX, y: pyT(temp)))
            g.line(to: NSPoint(x: plot.maxX, y: pyT(temp)))
            g.stroke()
            drawText("\(Int(temp))°", at: NSPoint(x: 4, y: pyT(temp) - 5), size: 9, color: .secondaryLabelColor)
        }
        for rpm in [0.0, 4000.0, 8000.0] {
            drawText(rpm == 0 ? "0" : String(format: "%.0fk", rpm / 1000),
                     at: NSPoint(x: plot.maxX + 5, y: pyR(rpm) - 5), size: 9,
                     color: NSColor.systemTeal.withAlphaComponent(0.9))
        }
        drawText(timeLabel(), at: NSPoint(x: plot.minX, y: padB - 14), size: 9, color: .tertiaryLabelColor)
        drawText("现在", at: NSPoint(x: plot.maxX - 22, y: padB - 14), size: 9, color: .tertiaryLabelColor)

        let rline = NSBezierPath(); rline.lineWidth = 1.0
        rline.move(to: NSPoint(x: px(samples[0].ts), y: pyR(samples[0].rpm)))
        for s in samples.dropFirst() { rline.line(to: NSPoint(x: px(s.ts), y: pyR(s.rpm))) }
        NSColor.systemTeal.setStroke()
        rline.stroke()

        let tline = NSBezierPath(); tline.lineWidth = 1.6
        tline.move(to: NSPoint(x: px(samples[0].ts), y: pyT(samples[0].temp)))
        for s in samples.dropFirst() { tline.line(to: NSPoint(x: px(s.ts), y: pyT(s.temp))) }
        NSColor.labelColor.setStroke()
        tline.stroke()
    }

    private func timeLabel() -> String {
        switch windowSec {
        case 600: return "-10 分钟"
        case 1800: return "-30 分钟"
        case 3600: return "-1 小时"
        default: return "-2 小时"
        }
    }

    private func drawLegend() {
        var x: CGFloat = padL
        for (mode, name) in [("manual", "智能调速"), ("custom", "手动定速"), ("auto", "系统调度")] {
            modeColor(mode).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: 7, width: 7, height: 7)).fill()
            drawText(name, at: NSPoint(x: x + 10, y: 4), size: 9, color: .secondaryLabelColor)
            x += 10 + CGFloat(name.count) * 10 + 12
        }
        NSColor.systemTeal.setStroke()
        let seg = NSBezierPath(); seg.lineWidth = 2
        seg.move(to: NSPoint(x: x, y: 10)); seg.line(to: NSPoint(x: x + 12, y: 10)); seg.stroke()
        drawText("转速", at: NSPoint(x: x + 15, y: 4), size: 9, color: .secondaryLabelColor)
    }

    private func drawText(_ s: String, at p: NSPoint, size: CGFloat, color: NSColor, bold: Bool = false) {
        let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        (s as NSString).draw(at: p, withAttributes: [.font: font, .foregroundColor: color])
    }
}

// MARK: - 转速控件：实心点=实时转速，空心环=手动定速目标，实时点向目标滑动

final class SpeedControlView: NSView {
    var actual: Double = fanMin
    var setpoint: Double?             // 手动定速目标；nil = 非手动模式
    var isEnabled = true
    var dragging = false
    var onPick: ((Int) -> Void)?      // 松开时回调
    var onDrag: ((Int) -> Void)?      // 拖动过程回调（更新标签）

    private let inset: CGFloat = 16

    private func xFor(_ rpm: Double) -> CGFloat {
        inset + CGFloat((min(max(rpm, fanMin), fanMax) - fanMin) / (fanMax - fanMin)) * (bounds.width - inset * 2)
    }
    private func rpmFor(_ x: CGFloat) -> Double {
        let f = Double((x - inset) / (bounds.width - inset * 2))
        return fanMin + min(max(f, 0), 1) * (fanMax - fanMin)
    }

    override func draw(_ dirtyRect: NSRect) {
        let midY = bounds.midY
        // 轨道
        let track = NSBezierPath()
        track.lineWidth = 3
        track.lineCapStyle = .round
        track.move(to: NSPoint(x: inset, y: midY))
        track.line(to: NSPoint(x: bounds.width - inset, y: midY))
        (isEnabled ? NSColor.separatorColor : NSColor.separatorColor.withAlphaComponent(0.4)).setStroke()
        track.stroke()

        // 已达区段（轨道左端到实时点，青色）
        let reach = NSBezierPath()
        reach.lineWidth = 3
        reach.lineCapStyle = .round
        reach.move(to: NSPoint(x: inset, y: midY))
        reach.line(to: NSPoint(x: xFor(actual), y: midY))
        NSColor.systemTeal.withAlphaComponent(isEnabled ? 0.8 : 0.3).setStroke()
        reach.stroke()

        // 目标环（手动定速，橙色空心圆）
        if let sp = setpoint {
            let x = xFor(sp)
            let ring = NSBezierPath(ovalIn: NSRect(x: x - 7, y: midY - 7, width: 14, height: 14))
            ring.lineWidth = 2
            NSColor.systemOrange.setStroke()
            ring.stroke()
        }

        // 实时点（青色实心圆）
        let ax = xFor(actual)
        NSColor.systemTeal.setFill()
        NSBezierPath(ovalIn: NSRect(x: ax - 5, y: midY - 5, width: 10, height: 10)).fill()
    }

    override func mouseDown(with event: NSEvent) { handle(event, final: false) }
    override func mouseDragged(with event: NSEvent) { handle(event, final: false) }
    override func mouseUp(with event: NSEvent) { handle(event, final: true) }

    private func handle(_ event: NSEvent, final: Bool) {
        guard isEnabled else { return }
        let p = convert(event.locationInWindow, from: nil)
        let rpm = rpmFor(p.x)
        dragging = !final
        setpoint = rpm
        needsDisplay = true
        if final {
            onPick?(Int(rpm))
        } else {
            onDrag?(Int(rpm))
        }
    }
}


// MARK: - 控制面板窗口（不依赖菜单栏图标的完整控制入口）

final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class PanelController: NSObject, NSWindowDelegate {
    weak var app: AppDelegate?
    let window: NSWindow
    let info = NSTextField(labelWithString: "")
    let chart = ChartView(frame: NSRect(x: 20, y: 76, width: 320, height: 168))
    let speedLabel = NSTextField(labelWithString: "转速　--")
    let speed = SpeedControlView(frame: NSRect(x: 20, y: 282, width: 320, height: 24))
    let loginBox = NSButton(checkboxWithTitle: "登录时自动启动 Fanctl", target: nil, action: nil)
    let iconBox  = NSButton(checkboxWithTitle: "在菜单栏显示图标", target: nil, action: nil)
    var timer: Timer?

    init(app: AppDelegate) {
        self.app = app
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 470),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Fanctl 控制面板"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: 360, height: 470))

        info.frame = NSRect(x: 22, y: 14, width: 320, height: 54)
        info.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        root.addSubview(info)
        root.addSubview(chart)
        speedLabel.frame = NSRect(x: 22, y: 256, width: 320, height: 18)
        speedLabel.font = .systemFont(ofSize: 13)
        root.addSubview(speedLabel)
        speed.onDrag = { [weak self] rpm in
            self?.speedLabel.stringValue = "手动定速　\(rpm) RPM（松开生效）"
        }
        speed.onPick = { [weak self] rpm in
            self?.app?.writeCmd("set \(rpm)")
            self?.speedLabel.stringValue = "手动定速　\(rpm) RPM"
        }
        root.addSubview(speed)

        var x: CGFloat = 20
        for (title, verb) in [("智能调速", "resume"), ("最大转速", "max"), ("恢复系统调度", "pause")] {
            let b = NSButton(title: title, target: self, action: #selector(modeButton(_:)))
            b.bezelStyle = .rounded
            b.identifier = NSUserInterfaceItemIdentifier(verb)
            b.frame = NSRect(x: x, y: 322, width: title.count > 4 ? 130 : 100, height: 28)
            x += b.frame.width + 6
            root.addSubview(b)
        }

        loginBox.frame = NSRect(x: 22, y: 368, width: 320, height: 20)
        loginBox.target = self; loginBox.action = #selector(toggleLogin)
        iconBox.frame = NSRect(x: 22, y: 394, width: 320, height: 20)
        iconBox.target = self; iconBox.action = #selector(toggleIcon)
        root.addSubview(loginBox)
        root.addSubview(iconBox)
        let hint = NSTextField(wrappingLabelWithString: "取消菜单栏图标后，Fanctl 以程序坞应用形式运行，点按程序坞图标可随时回到本面板。开机自启设置于下次登录生效。")
        hint.frame = NSRect(x: 22, y: 418, width: 320, height: 40)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        root.addSubview(hint)

        window.contentView = root
        window.center()
    }

    func show() {
        syncChecks()
        refresh()
        chart.reload()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        timer?.invalidate()
        timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
            self?.chart.reload()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }

    func syncChecks() {
        loginBox.state = FileManager.default.fileExists(atPath: AppDelegate.agentPlistPath) ? .on : .off
        iconBox.state = AppDelegate.menuIconShown() ? .on : .off
    }

    @objc func modeButton(_ sender: NSButton) {
        if let verb = sender.identifier?.rawValue { app?.writeCmd(verb) }
    }

    @objc func toggleLogin() { AppDelegate.setLaunchAtLogin(loginBox.state == .on) }

    @objc func toggleIcon() {
        UserDefaults.standard.set(iconBox.state == .on, forKey: "showMenuIcon")
        app?.applyMenuIconVisibility()
    }

    func refresh() {
        guard let data = FileManager.default.contents(atPath: statusPath),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let j = obj as? [String: Any] else {
            info.stringValue = "后台服务未运行"
            return
        }
        let temp  = (j["temp"]  as? NSNumber)?.doubleValue ?? 0
        let rpm   = (j["rpm"]   as? NSNumber)?.doubleValue ?? 0
        let act   = (j["act"]   as? NSNumber)?.doubleValue ?? rpm
        let power = (j["power"] as? NSNumber)?.doubleValue ?? 0
        let mode  = j["mode"] as? String ?? "?"
        info.stringValue = String(format: "CPU 温度　%.1f °C\n整机功耗　%.1f W\n运行模式　%@",
                                  temp, power, modeName(mode, rpm: rpm))
        if !speed.dragging {
            speed.actual = act > 0 ? act : fanMin
            speed.setpoint = (mode == "custom") ? rpm : nil
            speed.needsDisplay = true
            speedLabel.stringValue = act > 0 ? "转速　\(Int(act)) RPM" : "转速　--"
        }
    }
}

// MARK: - 应用主体

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!
    lazy var panel = PanelController(app: self)

    static var agentPlistPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/io.fanctl.menubar.plist"
    }
    static func menuIconShown() -> Bool {
        UserDefaults.standard.object(forKey: "showMenuIcon") == nil
            ? true : UserDefaults.standard.bool(forKey: "showMenuIcon")
    }
    static func setLaunchAtLogin(_ on: Bool) {
        let fm = FileManager.default
        if on {
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>Label</key><string>io.fanctl.menubar</string>
            <key>ProgramArguments</key><array><string>/Applications/Fanctl.app/Contents/MacOS/fanctl-bar</string></array>
            <key>RunAtLoad</key><true/>
            </dict></plist>
            """
            try? fm.createDirectory(atPath: NSHomeDirectory() + "/Library/LaunchAgents",
                                    withIntermediateDirectories: true)
            try? plist.write(toFile: agentPlistPath, atomically: true, encoding: .utf8)
        } else {
            try? fm.removeItem(atPath: agentPlistPath)
        }
    }

    func applyMenuIconVisibility() {
        let show = AppDelegate.menuIconShown()
        item.isVisible = show
        NSApp.setActivationPolicy(show ? .accessory : .regular)
        if !show { panel.show() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        panel.show()
        return true
    }
    var slowTimer: Timer?
    var fastTimer: Timer?
    var fastTicks = 0
    var lastTitle = ""

    let tempRow  = NSMenuItem(title: "CPU 温度　--", action: nil, keyEquivalent: "")
    let powerRow = NSMenuItem(title: "整机功耗　--", action: nil, keyEquivalent: "")
    let modeRow  = NSMenuItem(title: "运行模式　--", action: nil, keyEquivalent: "")
    var smartItem: NSMenuItem!
    var pauseItem: NSMenuItem!
    var fullItem: NSMenuItem!
    var speedLabel: NSTextField!
    let speedControl = SpeedControlView(frame: NSRect(x: 14, y: 4, width: 292, height: 24))
    let chart = ChartView(frame: NSRect(x: 0, y: 0, width: 320, height: 168))

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "…°"
        let menu = NSMenu()
        menu.delegate = self

        for row in [tempRow, powerRow, modeRow] {
            row.isEnabled = false
            menu.addItem(row)
        }
        menu.addItem(.separator())

        let chartItem = NSMenuItem()
        chartItem.view = chart
        menu.addItem(chartItem)
        menu.addItem(.separator())

        let speedItem = NSMenuItem()
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 52))
        speedLabel = NSTextField(labelWithString: "转速　--")
        speedLabel.font = .menuFont(ofSize: 13)
        speedLabel.frame = NSRect(x: 14, y: 30, width: 292, height: 18)
        speedControl.onDrag = { [weak self] rpm in
            self?.speedLabel.stringValue = "手动定速　\(rpm) RPM（松开生效）"
        }
        speedControl.onPick = { [weak self] rpm in
            self?.writeCmd("set \(rpm)")
            self?.speedLabel.stringValue = "手动定速　\(rpm) RPM"
        }
        box.addSubview(speedLabel)
        box.addSubview(speedControl)
        speedItem.view = box
        menu.addItem(speedItem)
        menu.addItem(.separator())

        smartItem = makeItem("智能调速", #selector(cmdResume))
        fullItem  = makeItem("最大转速", #selector(cmdMax))
        pauseItem = makeItem("恢复系统调度", #selector(cmdPause))
        menu.addItem(smartItem)
        menu.addItem(fullItem)
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        menu.addItem(makeItem("控制面板…", #selector(openPanel)))
        menu.addItem(makeItem("安装 / 更新后台服务…", #selector(installService)))
        menu.addItem(makeItem("退出 Fanctl", #selector(quit)))
        item.menu = menu

        refresh()
        slowTimer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(slowTimer!, forMode: .common)

        applyMenuIconVisibility()
        if !FileManager.default.fileExists(atPath: daemonPlist) {
            promptInstall(firstRun: true)
        }
    }

    @objc func openPanel() { panel.show() }

    // MARK: 后台服务安装（内嵌于 App，首启一次授权）

    func promptInstall(firstRun: Bool) {
        let alert = NSAlert()
        alert.messageText = firstRun ? "安装 Fanctl 后台服务" : "更新 Fanctl 后台服务"
        alert.informativeText = "风扇控制需要一个以管理员权限运行的后台服务（安装一次，开机自启）。安装内容：smcfan、fanctld 及其启动项。"
        alert.addButton(withTitle: firstRun ? "安装" : "更新")
        alert.addButton(withTitle: "暂不")
        guard alert.runModal() == .alertFirstButtonReturn,
              let res = Bundle.main.resourcePath else { return }
        let cmd = "/bin/bash '\(res)/install-helper.sh' '\(res)'"
        let script = "do shell script \"\(cmd.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        if err != nil {
            let fail = NSAlert()
            fail.messageText = "安装未完成"
            fail.informativeText = "已取消或安装出错。可稍后从菜单「安装 / 更新后台服务…」重试。"
            fail.runModal()
        }
    }

    @objc func installService() { promptInstall(firstRun: !FileManager.default.fileExists(atPath: daemonPlist)) }

    // MARK: 刷新

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
        chart.reload()
        fastTicks = 0
        fastTimer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refresh()
            self.fastTicks += 1
            if self.fastTicks % 3 == 0 { self.chart.reload() }
        }
        RunLoop.main.add(fastTimer!, forMode: .common)
    }

    func menuDidClose(_ menu: NSMenu) {
        fastTimer?.invalidate()
        fastTimer = nil
    }

    func makeItem(_ title: String, _ sel: Selector) -> NSMenuItem {
        let m = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        m.target = self
        return m
    }

    func refresh() {
        guard let data = FileManager.default.contents(atPath: statusPath),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let j = obj as? [String: Any] else {
            setTitle("–°")
            modeRow.title = "运行模式　后台服务未运行"
            return
        }
        let temp  = (j["temp"]  as? NSNumber)?.doubleValue ?? 0
        let rpm   = (j["rpm"]   as? NSNumber)?.doubleValue ?? 0
        let act   = (j["act"]   as? NSNumber)?.doubleValue ?? rpm
        let power = (j["power"] as? NSNumber)?.doubleValue ?? 0
        let ts    = (j["ts"]    as? NSNumber)?.doubleValue ?? 0
        let mode  = j["mode"] as? String ?? "?"
        let stale = Date().timeIntervalSince1970 - ts > 90

        setTitle(stale ? "–°" : String(format: "%.0f°", temp))
        tempRow.title  = String(format: "CPU 温度　%.1f °C%@", temp, stale ? "（数据过期）" : "")
        powerRow.title = String(format: "整机功耗　%.1f W", power)
        modeRow.title  = "运行模式　" + modeName(mode, rpm: rpm)

        smartItem.state = (mode == "manual" || mode == "auto") ? .on : .off
        pauseItem.state = (mode == "paused") ? .on : .off
        fullItem.state  = (mode == "custom" && rpm >= fanMax - 50) ? .on : .off

        if !speedControl.dragging {
            speedControl.actual = act > 0 ? act : fanMin
            speedControl.setpoint = (mode == "custom") ? rpm : nil
            speedControl.isEnabled = (mode != "battery")
            speedControl.needsDisplay = true
            if mode == "custom", abs(act - rpm) > 150 {
                speedLabel.stringValue = "转速　\(Int(act)) → \(Int(rpm)) RPM"
            } else {
                speedLabel.stringValue = act > 0 ? "转速　\(Int(act)) RPM" : "转速　--"
            }
        }
    }

    func setTitle(_ t: String) {
        if t != lastTitle {
            item.button?.title = t
            lastTitle = t
        }
    }

    func writeCmd(_ verb: String) {
        try? verb.write(toFile: cmdPath, atomically: true, encoding: .utf8)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.refresh()
            self?.chart.reload()
        }
    }

    @objc func cmdResume() { writeCmd("resume") }
    @objc func cmdPause()  { writeCmd("pause") }
    @objc func cmdMax()    { writeCmd("max") }
    @objc func quit()      { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
