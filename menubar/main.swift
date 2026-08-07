// Fanctl menu bar app — minimal-cost status display
// Design rules (to stay cheap under Liquid Glass rendering):
//   * refreshes every 15s, and only redraws the title when the text actually changed
//   * reads a status file written by the daemon — never touches SMC directly
//   * actions are written to a verb file consumed by the daemon
import AppKit

let statusPath = "/tmp/fanctl-status.json"
let cmdPath = "/tmp/fanctl-cmd"

final class AppDelegate: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    var timer: Timer?
    var lastTitle = ""
    let tempRow  = NSMenuItem(title: "温度: --", action: nil, keyEquivalent: "")
    let fanRow   = NSMenuItem(title: "风扇: --", action: nil, keyEquivalent: "")
    let powerRow = NSMenuItem(title: "功耗: --", action: nil, keyEquivalent: "")
    let modeRow  = NSMenuItem(title: "模式: --", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "…°"
        let menu = NSMenu()
        for row in [tempRow, fanRow, powerRow, modeRow] {
            row.isEnabled = false
            menu.addItem(row)
        }
        menu.addItem(.separator())
        menu.addItem(makeItem("恢复智能温控", #selector(cmdResume)))
        menu.addItem(makeItem("暂停温控（交还系统）", #selector(cmdPause)))
        menu.addItem(makeItem("风扇拉满", #selector(cmdMax)))
        menu.addItem(.separator())
        menu.addItem(makeItem("退出", #selector(quit)))
        item.menu = menu
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.refresh()
        }
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
            modeRow.title = "模式: 守护进程未运行"
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
        switch mode {
        case "manual":
            fanRow.title = String(format: "风扇: %.0f rpm", rpm)
            modeRow.title = "模式: 智能温控中"
        case "auto":
            fanRow.title = "风扇: 系统自动"
            modeRow.title = "模式: 待命（温度未超阈值）"
        case "paused":
            fanRow.title = "风扇: 系统自动"
            modeRow.title = "模式: 已暂停"
        case "max":
            fanRow.title = "风扇: 全速"
            modeRow.title = "模式: 手动拉满"
        case "battery":
            fanRow.title = "风扇: 系统自动"
            modeRow.title = "模式: 电池供电（不介入）"
        default:
            fanRow.title = "风扇: --"
            modeRow.title = "模式: \(mode)"
        }
    }

    func setTitle(_ t: String) {
        if t != lastTitle {          // 内容没变绝不触发重绘
            item.button?.title = t
            lastTitle = t
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
