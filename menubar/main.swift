// Fanctl menu bar app
// Low-overhead by design:
//   * menu closed  -> 15s slow refresh, title redraws only on text change
//   * menu open    -> 2s live refresh (status/slider), chart reloads every 6s
//   * all data read from daemon-written files; never touches SMC directly
import AppKit

let statusPath  = "/tmp/fanctl-status.json"
let historyPath = "/tmp/fanctl-history.jsonl"
let cmdPath     = "/tmp/fanctl-cmd"
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
    case "auto":    return "待命 · 系统调度"
    case "custom":  return "手动定速 · \(Int(rpm)) RPM"
    case "paused":  return "已停用 · 系统调度"
    case "battery": return "电池供电 · 已停用"
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
        needsDisplay = true
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

        // 模式底色分段
        var i = 0
        while i < samples.count {
            var j = i
            while j + 1 < samples.count && samples[j + 1].mode == samples[i].mode { j += 1 }
            let x1 = px(samples[i].ts), x2 = max(px(samples[j].ts), x1 + 1)
            modeColor(samples[i].mode).withAlphaComponent(0.15).setFill()
            NSRect(x: x1, y: plot.minY, width: x2 - x1, height: plot.height).fill()
            i = j + 1
        }

        // 网格 + 左轴（温度）+ 右轴（转速）
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

        // 转速曲线（右轴，青色细线）
        let rline = NSBezierPath(); rline.lineWidth = 1.0
        rline.move(to: NSPoint(x: px(samples[0].ts), y: pyR(samples[0].rpm)))
        for s in samples.dropFirst() { rline.line(to: NSPoint(x: px(s.ts), y: pyR(s.rpm))) }
        NSColor.systemTeal.setStroke()
        rline.stroke()

        // 温度曲线（左轴，主色粗线）
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

// MARK: - 应用主体

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!
    var slowTimer: Timer?
    var fastTimer: Timer?
    var fastTicks = 0
    var lastTitle = ""
    var dragging = false

    let tempRow  = NSMenuItem(title: "CPU 温度　--", action: nil, keyEquivalent: "")
    let powerRow = NSMenuItem(title: "整机功耗　--", action: nil, keyEquivalent: "")
    let modeRow  = NSMenuItem(title: "运行模式　--", action: nil, keyEquivalent: "")
    var smartItem: NSMenuItem!
    var pauseItem: NSMenuItem!
    var fullItem: NSMenuItem!
    var slider: NSSlider!
    var sliderLabel: NSTextField!
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

        let sliderItem = NSMenuItem()
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 52))
        sliderLabel = NSTextField(labelWithString: "当前转速")
        sliderLabel.font = .menuFont(ofSize: 13)
        sliderLabel.frame = NSRect(x: 14, y: 30, width: 292, height: 18)
        slider = NSSlider(value: fanMin, minValue: fanMin, maxValue: fanMax,
                          target: self, action: #selector(sliderMoved(_:)))
        slider.frame = NSRect(x: 14, y: 4, width: 292, height: 24)
        slider.isContinuous = true
        box.addSubview(sliderLabel)
        box.addSubview(slider)
        sliderItem.view = box
        menu.addItem(sliderItem)
        menu.addItem(.separator())

        smartItem = makeItem("智能调速", #selector(cmdResume))
        fullItem  = makeItem("全速运行", #selector(cmdMax))
        pauseItem = makeItem("停用（风扇交由系统调度）", #selector(cmdPause))
        menu.addItem(smartItem)
        menu.addItem(fullItem)
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        menu.addItem(makeItem("退出 Fanctl", #selector(quit)))
        item.menu = menu

        refresh()
        slowTimer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(slowTimer!, forMode: .common)
    }

    // 菜单展开 -> 2s 实时刷新；收起 -> 回到 15s 慢刷
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
            modeRow.title = "运行模式　守护进程未运行"
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

        if !dragging {
            let shown = act > 0 ? act : fanMin
            slider.doubleValue = min(max(shown, fanMin), fanMax)
            sliderLabel.stringValue = act > 0
                ? "当前转速　\(Int(act)) RPM"
                : "当前转速　--"
            slider.isEnabled = (mode != "battery")
        }
    }

    func setTitle(_ t: String) {
        if t != lastTitle {
            item.button?.title = t
            lastTitle = t
        }
    }

    @objc func sliderMoved(_ s: NSSlider) {
        let rpm = Int(s.doubleValue)
        dragging = true
        sliderLabel.stringValue = "目标转速　\(rpm) RPM（松开生效 · 手动定速）"
        if NSApp.currentEvent?.type == .leftMouseUp {
            dragging = false
            writeCmd("set \(rpm)")
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
