// Fanctl menu bar app — localized (en/zh/ja/ko/es/fr/de/ru)
// Low-overhead by design: 15s refresh closed / 2s open; UI reads daemon status
// files only and never touches SMC directly.
import AppKit

let statusPath  = "/tmp/fanctl-status.json"
let historyPath = "/tmp/fanctl-history.jsonl"
let cmdPath     = "/tmp/fanctl-cmd"
let daemonPlist = "/Library/LaunchDaemons/io.fanctl.daemon.plist"
let feedbackEmail = "tomeageer@gmail.com"
let websiteURL    = "https://tomeageer.com"
let fanMin = 2317.0
let fanMax = 7826.0
let rpmAxisMax = 8000.0

// MARK: - 本地化

let uiLang: String = {
    let p = Locale.preferredLanguages.first ?? "en"
    for c in ["zh", "ja", "ko", "es", "fr", "de", "ru"] where p.hasPrefix(c) { return c }
    return "en"
}()

func T(_ key: String) -> String {
    L10N[key]?[uiLang] ?? L10N[key]?["en"] ?? key
}

let L10N: [String: [String: String]] = [
    "smart":        ["en": "Smart Control", "zh": "智能调速", "ja": "スマート制御", "ko": "스마트 제어",
                     "es": "Control inteligente", "fr": "Régulation intelligente", "de": "Intelligente Regelung", "ru": "Умное управление"],
    "smartStandby": ["en": "Smart · Standby", "zh": "智能调速 · 待命", "ja": "スマート · 待機", "ko": "스마트 · 대기",
                     "es": "Inteligente · En espera", "fr": "Intelligente · Veille", "de": "Intelligent · Bereitschaft", "ru": "Умное · Ожидание"],
    "manual":       ["en": "Manual", "zh": "手动定速", "ja": "手動固定", "ko": "수동 고정",
                     "es": "Manual", "fr": "Manuel", "de": "Manuell", "ru": "Ручной"],
    "systemSched":  ["en": "System Scheduling", "zh": "系统调度", "ja": "システム制御", "ko": "시스템 제어",
                     "es": "Gestión del sistema", "fr": "Gestion système", "de": "Systemsteuerung", "ru": "Системное управление"],
    "batteryMode":  ["en": "On Battery · System", "zh": "电池供电 · 系统调度", "ja": "バッテリー · システム", "ko": "배터리 · 시스템",
                     "es": "Batería · Sistema", "fr": "Batterie · Système", "de": "Akku · System", "ru": "Батарея · Система"],
    "cpuTemp":      ["en": "CPU Temp", "zh": "CPU 温度", "ja": "CPU温度", "ko": "CPU 온도",
                     "es": "Temp. CPU", "fr": "Temp. CPU", "de": "CPU-Temp.", "ru": "Темп. CPU"],
    "sysPower":     ["en": "Power", "zh": "整机功耗", "ja": "消費電力", "ko": "시스템 전력",
                     "es": "Consumo", "fr": "Consommation", "de": "Leistung", "ru": "Мощность"],
    "runMode":      ["en": "Mode", "zh": "运行模式", "ja": "モード", "ko": "모드",
                     "es": "Modo", "fr": "Mode", "de": "Modus", "ru": "Режим"],
    "chartTitle":   ["en": "Temp / RPM History", "zh": "温度 / 转速历史", "ja": "温度 / 回転数の履歴", "ko": "온도 / 회전수 기록",
                     "es": "Historial temp/RPM", "fr": "Historique temp/RPM", "de": "Temp-/Drehzahlverlauf", "ru": "История темп./оборотов"],
    "rpm":          ["en": "RPM", "zh": "转速", "ja": "回転数", "ko": "회전수",
                     "es": "RPM", "fr": "RPM", "de": "Drehzahl", "ru": "Обороты"],
    "win10":        ["en": "10 min", "zh": "10 分", "ja": "10分", "ko": "10분", "es": "10 min", "fr": "10 min", "de": "10 Min", "ru": "10 мин"],
    "win30":        ["en": "30 min", "zh": "30 分", "ja": "30分", "ko": "30분", "es": "30 min", "fr": "30 min", "de": "30 Min", "ru": "30 мин"],
    "win1h":        ["en": "1 h", "zh": "1 时", "ja": "1時間", "ko": "1시간", "es": "1 h", "fr": "1 h", "de": "1 Std", "ru": "1 ч"],
    "win2h":        ["en": "2 h", "zh": "2 时", "ja": "2時間", "ko": "2시간", "es": "2 h", "fr": "2 h", "de": "2 Std", "ru": "2 ч"],
    "now":          ["en": "now", "zh": "现在", "ja": "現在", "ko": "현재", "es": "ahora", "fr": "maintenant", "de": "jetzt", "ru": "сейчас"],
    "collecting":   ["en": "Collecting data…", "zh": "正在采集数据…", "ja": "データ収集中…", "ko": "데이터 수집 중…",
                     "es": "Recopilando datos…", "fr": "Collecte des données…", "de": "Daten werden gesammelt…", "ru": "Сбор данных…"],
    "fanSpeed":     ["en": "Fan Speed", "zh": "风扇转速", "ja": "ファン回転数", "ko": "팬 속도",
                     "es": "Velocidad del ventilador", "fr": "Vitesse du ventilateur", "de": "Lüftergeschwindigkeit", "ru": "Скорость вентилятора"],
    "releaseApply": ["en": "release to apply", "zh": "松开生效", "ja": "離すと適用", "ko": "놓으면 적용",
                     "es": "suelte para aplicar", "fr": "relâcher pour appliquer", "de": "loslassen zum Anwenden", "ru": "отпустите для применения"],
    "maxSpeed":     ["en": "Max Speed", "zh": "最大转速", "ja": "最大回転", "ko": "최대 속도",
                     "es": "Velocidad máxima", "fr": "Vitesse max", "de": "Maximale Drehzahl", "ru": "Макс. обороты"],
    "restoreSys":   ["en": "Restore System Control", "zh": "恢复系统调度", "ja": "システム制御に戻す", "ko": "시스템 제어로 복원",
                     "es": "Restaurar control del sistema", "fr": "Rendre au système", "de": "System übernehmen lassen", "ru": "Вернуть системе"],
    "panel":        ["en": "Control Panel…", "zh": "控制面板…", "ja": "コントロールパネル…", "ko": "제어판…",
                     "es": "Panel de control…", "fr": "Panneau de contrôle…", "de": "Kontrollpanel…", "ru": "Панель управления…"],
    "installSvc":   ["en": "Install / Update Service…", "zh": "安装 / 更新后台服务…", "ja": "サービスをインストール / 更新…", "ko": "서비스 설치 / 업데이트…",
                     "es": "Instalar / actualizar servicio…", "fr": "Installer / mettre à jour le service…", "de": "Dienst installieren / aktualisieren…", "ru": "Установить / обновить службу…"],
    "feedback":     ["en": "Send Feedback", "zh": "发送反馈", "ja": "フィードバックを送る", "ko": "피드백 보내기",
                     "es": "Enviar comentarios", "fr": "Envoyer un retour", "de": "Feedback senden", "ru": "Отправить отзыв"],
    "quit":         ["en": "Quit Fanctl", "zh": "退出 Fanctl", "ja": "Fanctl を終了", "ko": "Fanctl 종료",
                     "es": "Salir de Fanctl", "fr": "Quitter Fanctl", "de": "Fanctl beenden", "ru": "Выйти из Fanctl"],
    "svcDown":      ["en": "Service not running", "zh": "后台服务未运行", "ja": "サービスが動作していません", "ko": "서비스가 실행되지 않음",
                     "es": "Servicio no activo", "fr": "Service inactif", "de": "Dienst läuft nicht", "ru": "Служба не запущена"],
    "stale":        ["en": " (stale)", "zh": "（数据过期）", "ja": "（データ期限切れ）", "ko": " (오래된 데이터)",
                     "es": " (obsoleto)", "fr": " (périmé)", "de": " (veraltet)", "ru": " (устарело)"],
    "settings":     ["en": "Settings", "zh": "设置", "ja": "設定", "ko": "설정",
                     "es": "Ajustes", "fr": "Réglages", "de": "Einstellungen", "ru": "Настройки"],
    "loginStart":   ["en": "Launch Fanctl at login", "zh": "登录时自动启动 Fanctl", "ja": "ログイン時に Fanctl を起動", "ko": "로그인 시 Fanctl 시작",
                     "es": "Iniciar Fanctl al iniciar sesión", "fr": "Lancer Fanctl à la connexion", "de": "Fanctl beim Anmelden starten", "ru": "Запускать Fanctl при входе"],
    "showIcon":     ["en": "Show menu bar icon", "zh": "在菜单栏显示图标", "ja": "メニューバーにアイコンを表示", "ko": "메뉴 막대에 아이콘 표시",
                     "es": "Mostrar icono en la barra de menús", "fr": "Afficher l'icône dans la barre de menus", "de": "Symbol in der Menüleiste anzeigen", "ru": "Показывать значок в строке меню"],
    "hint":         ["en": "With the menu bar icon hidden, Fanctl runs as a Dock app — click its Dock icon to reopen this panel. Login item changes take effect at next login.",
                     "zh": "隐藏菜单栏图标后，Fanctl 转为程序坞应用，点按程序坞图标即可回到本面板；开机自启于下次登录生效。",
                     "ja": "メニューバーアイコンを隠すと Fanctl は Dock アプリとして動作します。Dock アイコンをクリックするとこのパネルに戻れます。ログイン項目は次回ログイン時に有効になります。",
                     "ko": "메뉴 막대 아이콘을 숨기면 Fanctl은 Dock 앱으로 실행됩니다. Dock 아이콘을 클릭하면 이 패널로 돌아옵니다. 로그인 항목은 다음 로그인부터 적용됩니다.",
                     "es": "Con el icono oculto, Fanctl funciona como app del Dock: haga clic en su icono del Dock para volver a este panel. El inicio de sesión se aplica en el próximo inicio.",
                     "fr": "Icône masquée, Fanctl fonctionne comme app du Dock : cliquez sur son icône du Dock pour rouvrir ce panneau. Le démarrage à la connexion prend effet à la prochaine session.",
                     "de": "Bei ausgeblendetem Menüleistensymbol läuft Fanctl als Dock-App — klicken Sie auf das Dock-Symbol, um dieses Panel zu öffnen. Anmeldeobjekte gelten ab der nächsten Anmeldung.",
                     "ru": "Если значок скрыт, Fanctl работает как приложение Dock — щёлкните его значок в Dock, чтобы открыть панель. Автозапуск вступит в силу при следующем входе."],
    "installTitle": ["en": "Install Fanctl Background Service", "zh": "安装 Fanctl 后台服务", "ja": "Fanctl バックグラウンドサービスをインストール", "ko": "Fanctl 백그라운드 서비스 설치",
                     "es": "Instalar el servicio de Fanctl", "fr": "Installer le service Fanctl", "de": "Fanctl-Hintergrunddienst installieren", "ru": "Установка фоновой службы Fanctl"],
    "updateTitle":  ["en": "Update Fanctl Background Service", "zh": "更新 Fanctl 后台服务", "ja": "Fanctl サービスを更新", "ko": "Fanctl 서비스 업데이트",
                     "es": "Actualizar el servicio de Fanctl", "fr": "Mettre à jour le service Fanctl", "de": "Fanctl-Dienst aktualisieren", "ru": "Обновление службы Fanctl"],
    "installMsg":   ["en": "Fan control requires a privileged background service (installed once, runs at boot). Installs: smcfan, fanctld and its launch item.",
                     "zh": "风扇控制需要一个以管理员权限运行的后台服务（安装一次，开机自启）。安装内容：smcfan、fanctld 及其启动项。",
                     "ja": "ファン制御には管理者権限のバックグラウンドサービスが必要です（1回のインストールで起動時に実行）。インストール内容：smcfan、fanctld と起動項目。",
                     "ko": "팬 제어에는 관리자 권한의 백그라운드 서비스가 필요합니다(한 번 설치, 부팅 시 실행). 설치 항목: smcfan, fanctld 및 시작 항목.",
                     "es": "El control del ventilador requiere un servicio con privilegios (se instala una vez, se ejecuta al arrancar). Instala: smcfan, fanctld y su elemento de inicio.",
                     "fr": "Le contrôle du ventilateur nécessite un service privilégié (installé une fois, lancé au démarrage). Installe : smcfan, fanctld et son élément de démarrage.",
                     "de": "Die Lüftersteuerung benötigt einen privilegierten Hintergrunddienst (einmalige Installation, startet beim Booten). Installiert: smcfan, fanctld und das Startobjekt.",
                     "ru": "Для управления вентилятором нужна привилегированная фоновая служба (устанавливается один раз, запускается при загрузке). Устанавливает: smcfan, fanctld и элемент запуска."],
    "installBtn":   ["en": "Install", "zh": "安装", "ja": "インストール", "ko": "설치", "es": "Instalar", "fr": "Installer", "de": "Installieren", "ru": "Установить"],
    "updateBtn":    ["en": "Update", "zh": "更新", "ja": "更新", "ko": "업데이트", "es": "Actualizar", "fr": "Mettre à jour", "de": "Aktualisieren", "ru": "Обновить"],
    "laterBtn":     ["en": "Not Now", "zh": "暂不", "ja": "後で", "ko": "나중에", "es": "Ahora no", "fr": "Plus tard", "de": "Später", "ru": "Не сейчас"],
    "failTitle":    ["en": "Installation Incomplete", "zh": "安装未完成", "ja": "インストール未完了", "ko": "설치 미완료",
                     "es": "Instalación incompleta", "fr": "Installation incomplète", "de": "Installation unvollständig", "ru": "Установка не завершена"],
    "failMsg":      ["en": "Cancelled or failed. Retry anytime via \"Install / Update Service…\" in the menu.",
                     "zh": "已取消或安装出错。可稍后从菜单「安装 / 更新后台服务…」重试。",
                     "ja": "キャンセルまたは失敗しました。メニューの「サービスをインストール / 更新…」から再試行できます。",
                     "ko": "취소되었거나 실패했습니다. 메뉴의 \"서비스 설치 / 업데이트…\"에서 다시 시도하세요.",
                     "es": "Cancelado o con error. Reintente desde \"Instalar / actualizar servicio…\" en el menú.",
                     "fr": "Annulé ou échoué. Réessayez via « Installer / mettre à jour le service… » dans le menu.",
                     "de": "Abgebrochen oder fehlgeschlagen. Über \"Dienst installieren / aktualisieren…\" im Menü erneut versuchen.",
                     "ru": "Отменено или произошла ошибка. Повторите через «Установить / обновить службу…» в меню."],
]

struct Sample { let ts, temp: Double; let rpm: Double; let mode: String }

func modeColor(_ mode: String) -> NSColor {
    switch mode {
    case "manual":  return .systemBlue
    case "custom":  return .systemOrange
    case "battery": return .systemGreen
    default:        return .systemGray
    }
}

func modeName(_ mode: String, rpm: Double) -> String {
    switch mode {
    case "manual":  return T("smart")
    case "auto":    return T("smartStandby")
    case "custom":  return "\(T("manual")) · \(Int(rpm)) RPM"
    case "paused":  return T("systemSched")
    case "battery": return T("batteryMode")
    default:        return mode
    }
}

// MARK: - 温度/转速历史曲线

final class ChartView: NSView {
    var samples: [Sample] = []
    var windowSec: Double = Double(UserDefaults.standard.integer(forKey: "chartWindow") == 0
                                   ? 1800 : UserDefaults.standard.integer(forKey: "chartWindow"))
    let windowOptions: [(String, Double)] = [(T("win10"), 600), (T("win30"), 1800), (T("win1h"), 3600), (T("win2h"), 7200)]
    var segmented: NSSegmentedControl!

    private let padL: CGFloat = 30, padR: CGFloat = 34, padT: CGFloat = 26, padB: CGFloat = 30

    override init(frame: NSRect) {
        super.init(frame: frame)
        segmented = NSSegmentedControl(labels: windowOptions.map { $0.0 },
                                       trackingMode: .selectOne, target: self,
                                       action: #selector(windowChanged(_:)))
        segmented.controlSize = .mini
        segmented.font = .systemFont(ofSize: 9)
        segmented.frame = NSRect(x: frame.width - 170, y: frame.height - 22, width: 164, height: 18)
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
        drawText("\(T("chartTitle")) · \(title)",
                 at: NSPoint(x: padL, y: bounds.height - 18), size: 11, color: .labelColor, bold: true)
        drawLegend()

        guard samples.count >= 2 else {
            drawText(T("collecting"), at: NSPoint(x: plot.midX - 40, y: plot.midY),
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
        drawText("-" + title, at: NSPoint(x: plot.minX, y: padB - 14), size: 9, color: .tertiaryLabelColor)
        drawText(T("now"), at: NSPoint(x: plot.maxX - 34, y: padB - 14), size: 9, color: .tertiaryLabelColor)

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

    private func drawLegend() {
        var x: CGFloat = padL
        for (mode, name) in [("manual", T("smart")), ("custom", T("manual")), ("auto", T("systemSched"))] {
            modeColor(mode).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: 7, width: 7, height: 7)).fill()
            drawText(name, at: NSPoint(x: x + 10, y: 4), size: 9, color: .secondaryLabelColor)
            x += 10 + name.size(withAttributes: [.font: NSFont.systemFont(ofSize: 9)]).width + 12
        }
        NSColor.systemTeal.setStroke()
        let seg = NSBezierPath(); seg.lineWidth = 2
        seg.move(to: NSPoint(x: x, y: 10)); seg.line(to: NSPoint(x: x + 12, y: 10)); seg.stroke()
        drawText(T("rpm"), at: NSPoint(x: x + 15, y: 4), size: 9, color: .secondaryLabelColor)
    }

    private func drawText(_ s: String, at p: NSPoint, size: CGFloat, color: NSColor, bold: Bool = false) {
        let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        (s as NSString).draw(at: p, withAttributes: [.font: font, .foregroundColor: color])
    }
}

// MARK: - 转速控件

final class SpeedControlView: NSView {
    var actual: Double = fanMin
    var setpoint: Double?
    var isEnabled = true
    var dragging = false
    var onPick: ((Int) -> Void)?
    var onDrag: ((Int) -> Void)?

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
        let track = NSBezierPath()
        track.lineWidth = 3
        track.lineCapStyle = .round
        track.move(to: NSPoint(x: inset, y: midY))
        track.line(to: NSPoint(x: bounds.width - inset, y: midY))
        (isEnabled ? NSColor.separatorColor : NSColor.separatorColor.withAlphaComponent(0.4)).setStroke()
        track.stroke()

        let reach = NSBezierPath()
        reach.lineWidth = 3
        reach.lineCapStyle = .round
        reach.move(to: NSPoint(x: inset, y: midY))
        reach.line(to: NSPoint(x: xFor(actual), y: midY))
        NSColor.systemTeal.withAlphaComponent(isEnabled ? 0.8 : 0.3).setStroke()
        reach.stroke()

        if let sp = setpoint {
            let x = xFor(sp)
            let ring = NSBezierPath(ovalIn: NSRect(x: x - 7, y: midY - 7, width: 14, height: 14))
            ring.lineWidth = 2
            NSColor.systemOrange.setStroke()
            ring.stroke()
        }

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
        if final { onPick?(Int(rpm)) } else { onDrag?(Int(rpm)) }
    }
}

// MARK: - 控制面板窗口

final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class PanelController: NSObject, NSWindowDelegate {
    weak var app: AppDelegate?
    let window: NSWindow
    let tempBig = NSTextField(labelWithString: "--")
    let subLine = NSTextField(labelWithString: "--")
    let chart = ChartView(frame: NSRect(x: 24, y: 96, width: 340, height: 186))
    let speedLabel = NSTextField(labelWithString: "--")
    let speed = SpeedControlView(frame: NSRect(x: 24, y: 352, width: 340, height: 24))
    let loginBox = NSButton(checkboxWithTitle: T("loginStart"), target: nil, action: nil)
    let iconBox  = NSButton(checkboxWithTitle: T("showIcon"), target: nil, action: nil)
    var timer: Timer?

    private func sectionLabel(_ text: String, y: CGFloat) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 11, weight: .semibold)
        l.textColor = .secondaryLabelColor
        l.frame = NSRect(x: 24, y: y, width: 340, height: 15)
        return l
    }

    private func separator(y: CGFloat) -> NSBox {
        let b = NSBox(frame: NSRect(x: 24, y: y, width: 340, height: 1))
        b.boxType = .separator
        return b
    }

    init(app: AppDelegate) {
        self.app = app
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 388, height: 606),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Fanctl"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: 388, height: 606))

        tempBig.font = .monospacedDigitSystemFont(ofSize: 40, weight: .semibold)
        tempBig.frame = NSRect(x: 24, y: 16, width: 260, height: 48)
        root.addSubview(tempBig)
        subLine.font = .systemFont(ofSize: 13)
        subLine.textColor = .secondaryLabelColor
        subLine.frame = NSRect(x: 26, y: 64, width: 340, height: 18)
        root.addSubview(subLine)

        root.addSubview(chart)

        root.addSubview(separator(y: 296))
        root.addSubview(sectionLabel(T("fanSpeed"), y: 308))
        speedLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        speedLabel.frame = NSRect(x: 24, y: 326, width: 340, height: 20)
        root.addSubview(speedLabel)
        speed.onDrag = { [weak self] rpm in
            self?.speedLabel.stringValue = "\(rpm) RPM · \(T("manual"))（\(T("releaseApply"))）"
        }
        speed.onPick = { [weak self] rpm in
            self?.app?.writeCmd("set \(rpm)")
            self?.speedLabel.stringValue = "\(rpm) RPM · \(T("manual"))"
        }
        root.addSubview(speed)

        let titles = [(T("smart"), "resume"), (T("maxSpeed"), "max"), (T("restoreSys"), "pause")]
        let bw: CGFloat = (340 - 16) / 3
        for (i, (title, verb)) in titles.enumerated() {
            let b = NSButton(title: title, target: self, action: #selector(modeButton(_:)))
            b.bezelStyle = .rounded
            b.controlSize = .large
            b.font = .systemFont(ofSize: 12)
            b.identifier = NSUserInterfaceItemIdentifier(verb)
            b.frame = NSRect(x: 24 + CGFloat(i) * (bw + 8), y: 392, width: bw, height: 32)
            root.addSubview(b)
        }

        root.addSubview(separator(y: 444))
        root.addSubview(sectionLabel(T("settings"), y: 456))
        loginBox.frame = NSRect(x: 24, y: 478, width: 340, height: 20)
        loginBox.target = self; loginBox.action = #selector(toggleLogin)
        iconBox.frame = NSRect(x: 24, y: 502, width: 340, height: 20)
        iconBox.target = self; iconBox.action = #selector(toggleIcon)
        root.addSubview(loginBox)
        root.addSubview(iconBox)
        let hint = NSTextField(wrappingLabelWithString: T("hint"))
        hint.frame = NSRect(x: 24, y: 526, width: 340, height: 44)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        root.addSubview(hint)

        let mail = NSButton(title: "✉ \(feedbackEmail)", target: self, action: #selector(openMail))
        mail.isBordered = false
        mail.contentTintColor = .linkColor
        mail.font = .systemFont(ofSize: 11)
        mail.frame = NSRect(x: 20, y: 574, width: 200, height: 18)
        let site = NSButton(title: "🌐 tomeageer.com", target: self, action: #selector(openSite))
        site.isBordered = false
        site.contentTintColor = .linkColor
        site.font = .systemFont(ofSize: 11)
        site.frame = NSRect(x: 228, y: 574, width: 140, height: 18)
        root.addSubview(mail)
        root.addSubview(site)

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

    @objc func openMail() {
        NSWorkspace.shared.open(URL(string: "mailto:\(feedbackEmail)?subject=Fanctl%20Feedback")!)
    }

    @objc func openSite() {
        NSWorkspace.shared.open(URL(string: websiteURL)!)
    }

    func refresh() {
        guard let data = FileManager.default.contents(atPath: statusPath),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let j = obj as? [String: Any] else {
            tempBig.stringValue = "--"
            subLine.stringValue = T("svcDown")
            return
        }
        let temp  = (j["temp"]  as? NSNumber)?.doubleValue ?? 0
        let rpm   = (j["rpm"]   as? NSNumber)?.doubleValue ?? 0
        let act   = (j["act"]   as? NSNumber)?.doubleValue ?? rpm
        let power = (j["power"] as? NSNumber)?.doubleValue ?? 0
        let mode  = j["mode"] as? String ?? "?"
        tempBig.stringValue = String(format: "%.1f °C", temp)
        subLine.stringValue = String(format: "%.1f W · %@", power, modeName(mode, rpm: rpm))
        if !speed.dragging {
            speed.actual = act > 0 ? act : fanMin
            speed.setpoint = (mode == "custom") ? rpm : nil
            speed.needsDisplay = true
            speedLabel.stringValue = act > 0 ? "\(Int(act)) RPM" : "--"
        }
    }
}

// MARK: - 应用主体

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!
    lazy var panel = PanelController(app: self)
    var slowTimer: Timer?
    var fastTimer: Timer?
    var fastTicks = 0
    var lastTitle = ""

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

    let tempRow  = NSMenuItem(title: "\(T("cpuTemp"))　--", action: nil, keyEquivalent: "")
    let powerRow = NSMenuItem(title: "\(T("sysPower"))　--", action: nil, keyEquivalent: "")
    let modeRow  = NSMenuItem(title: "\(T("runMode"))　--", action: nil, keyEquivalent: "")
    var smartItem: NSMenuItem!
    var pauseItem: NSMenuItem!
    var fullItem: NSMenuItem!
    var speedLabel: NSTextField!
    let speedControl = SpeedControlView(frame: NSRect(x: 14, y: 4, width: 292, height: 24))
    let chart = ChartView(frame: NSRect(x: 0, y: 0, width: 320, height: 168))

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 单实例守卫：已有同 bundle id 实例在跑则直接退出（防手动启动/LaunchAgent 双开）
        let peers = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == "io.fanctl.menubar" && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        if !peers.isEmpty {
            NSApp.terminate(nil)
            return
        }
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
        speedLabel = NSTextField(labelWithString: T("rpm"))
        speedLabel.font = .menuFont(ofSize: 13)
        speedLabel.frame = NSRect(x: 14, y: 30, width: 292, height: 18)
        speedControl.onDrag = { [weak self] rpm in
            self?.speedLabel.stringValue = "\(T("manual"))　\(rpm) RPM（\(T("releaseApply"))）"
        }
        speedControl.onPick = { [weak self] rpm in
            self?.writeCmd("set \(rpm)")
            self?.speedLabel.stringValue = "\(T("manual"))　\(rpm) RPM"
        }
        box.addSubview(speedLabel)
        box.addSubview(speedControl)
        speedItem.view = box
        menu.addItem(speedItem)
        menu.addItem(.separator())

        smartItem = makeItem(T("smart"), #selector(cmdResume))
        fullItem  = makeItem(T("maxSpeed"), #selector(cmdMax))
        pauseItem = makeItem(T("restoreSys"), #selector(cmdPause))
        menu.addItem(smartItem)
        menu.addItem(fullItem)
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        menu.addItem(makeItem(T("panel"), #selector(openPanel)))
        menu.addItem(makeItem(T("installSvc"), #selector(installService)))
        menu.addItem(makeItem(T("feedback"), #selector(openFeedback)))
        menu.addItem(makeItem(T("quit"), #selector(quit)))
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

    @objc func openFeedback() {
        NSWorkspace.shared.open(URL(string: "mailto:\(feedbackEmail)?subject=Fanctl%20Feedback")!)
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

    func promptInstall(firstRun: Bool) {
        let alert = NSAlert()
        alert.messageText = firstRun ? T("installTitle") : T("updateTitle")
        alert.informativeText = T("installMsg")
        alert.addButton(withTitle: firstRun ? T("installBtn") : T("updateBtn"))
        alert.addButton(withTitle: T("laterBtn"))
        guard alert.runModal() == .alertFirstButtonReturn,
              let res = Bundle.main.resourcePath else { return }
        let cmd = "/bin/bash '\(res)/install-helper.sh' '\(res)'"
        let script = "do shell script \"\(cmd.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        if err != nil {
            let fail = NSAlert()
            fail.messageText = T("failTitle")
            fail.informativeText = T("failMsg")
            fail.runModal()
        }
    }

    @objc func installService() { promptInstall(firstRun: !FileManager.default.fileExists(atPath: daemonPlist)) }

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
            modeRow.title = "\(T("runMode"))　\(T("svcDown"))"
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
        tempRow.title  = String(format: "%@　%.1f °C%@", T("cpuTemp"), temp, stale ? T("stale") : "")
        powerRow.title = String(format: "%@　%.1f W", T("sysPower"), power)
        modeRow.title  = "\(T("runMode"))　" + modeName(mode, rpm: rpm)

        smartItem.state = (mode == "manual" || mode == "auto") ? .on : .off
        pauseItem.state = (mode == "paused") ? .on : .off
        fullItem.state  = (mode == "custom" && rpm >= fanMax - 50) ? .on : .off

        if !speedControl.dragging {
            speedControl.actual = act > 0 ? act : fanMin
            speedControl.setpoint = (mode == "custom") ? rpm : nil
            speedControl.isEnabled = (mode != "battery")
            speedControl.needsDisplay = true
            if mode == "custom", abs(act - rpm) > 150 {
                speedLabel.stringValue = "\(T("rpm"))　\(Int(act)) → \(Int(rpm)) RPM"
            } else {
                speedLabel.stringValue = act > 0 ? "\(T("rpm"))　\(Int(act)) RPM" : "\(T("rpm"))　--"
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
