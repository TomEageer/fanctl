// Fanctl menu bar app — minimal-cost status display + custom speed slider
// Design rules (to stay cheap under Liquid Glass rendering):
//   * timer refresh every 15s; the title only redraws when its text actually changed
//   * opening the menu triggers an immediate refresh (menuWillOpen)
//   * reads the daemon's status file — never touches SMC directly
//   * dragging the slider switches the daemon into custom-speed mode
import AppKit

let statusPath = "/tmp/fanctl-status.json"
let cmdPath = "/tmp/fanctl-cmd"
let fanMin = 2317.0
let fanMax = 7826.0

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!
    var timer: Timer?
    var lastTitle = ""
    var dragging = false

    let tempRow  = NSMenuItem(title: "温度: --", action: nil, keyEquivalent: "")
    let powerRow = NSMenuItem(title: "功耗: --", action: nil, keyEquivalent: "")
    let modeRow  = NSMenuItem(title: "模式: --", action: nil, keyEquivalent: "")
    var smartItem: NSMenuItem!
    var pauseItem: NSMenuItem!
    var maxItem: NSMenuItem!
    var slider: NSSlider!
    var sliderLabel: NSTextField!

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

        // 转速拉条：实时显示，拖动即切自定义转速
        let sliderItem = NSMenuItem()
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 54))
        sliderLabel = NSTextField(labelWithString: "风扇转速: --")
        sliderLabel.font = .menuFont(ofSize: 13)
        sliderLabel.frame = NSRect(x: 14, y: 32, width: 222, height: 18)
        slider = NSSlider(value: fanMin, minValue: fanMin, maxValue: fanMax,
                          target: self, action: #selector(sliderMoved(_:)))
        slider.frame = NSRect(x: 14, y: 6, width: 222, height: 24)
        slider.isContinuous = true
        box.addSubview(sliderLabel)
        box.addSubview(slider)
        sliderItem.view = box
        menu.addItem(sliderItem)
        menu.addItem(.separator())

        smartItem = makeItem("智能温控", #selector(cmdResume))
        pauseItem = makeItem("暂停（交还系统）", #selector(cmdPause))
        maxItem   = makeItem("风扇拉满", #selector(cmdMax))
        menu.addItem(smartItem)
        menu.addItem(pauseItem)
        menu.addItem(maxItem)
        menu.addItem(.separator())
        menu.addItem(makeItem("退出", #selector(quit)))
        item.menu = menu

        refresh()
        timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer!, forMode: .common)   // 菜单展开期间也照常刷新
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() } // 点开即最新，不等下个刷新周期

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
            modeRow.title = "模式: 守护进程未运行"
            sliderLabel.stringValue = "风扇转速: --"
            return
        }
        let temp  = (j["temp"]  as? NSNumber)?.doubleValue ?? 0
        let rpm   = (j["rpm"]   as? NSNumber)?.doubleValue ?? 0
        let power = (j["power"] as? NSNumber)?.doubleValue ?? 0
        let ts    = (j["ts"]    as? NSNumber)?.doubleValue ?? 0
        let mode  = j["mode"] as? String ?? "?"
        let stale = Date().timeIntervalSince1970 - ts > 90

        setTitle(stale ? "–°" : String(format: "%.0f°", temp))
        tempRow.title  = String(format: "温度: %.1f °C%@", temp, stale ? "（数据过期）" : "")
        powerRow.title = String(format: "功耗: %.1f W", power)

        let modeName: String
        switch mode {
        case "manual":  modeName = "智能温控中（\(Int(rpm)) rpm）"
        case "auto":    modeName = "待命 · 系统自动（温度未超阈值）"
        case "custom":  modeName = "自定义转速（\(Int(rpm)) rpm）"
        case "paused":  modeName = "已暂停 · 系统自动"
        case "battery": modeName = "电池供电 · 不介入"
        default:        modeName = mode
        }
        modeRow.title = "模式: " + modeName

        smartItem.state = (mode == "manual" || mode == "auto") ? .on : .off
        pauseItem.state = (mode == "paused") ? .on : .off
        maxItem.state   = (mode == "custom" && rpm >= fanMax - 50) ? .on : .off

        if !dragging {
            if rpm > 0 {
                slider.doubleValue = rpm
                sliderLabel.stringValue = "风扇转速: \(Int(rpm)) rpm（拖动切自定义）"
            } else {
                slider.doubleValue = fanMin
                sliderLabel.stringValue = "风扇转速: 系统自动（拖动切自定义）"
            }
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
        sliderLabel.stringValue = "自定义转速: \(rpm) rpm"
        if NSApp.currentEvent?.type == .leftMouseUp {   // 松手才下发指令
            dragging = false
            writeCmd("set \(rpm)")
        }
    }

    func writeCmd(_ verb: String) {
        try? verb.write(toFile: cmdPath, atomically: true, encoding: .utf8)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.refresh() }
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
