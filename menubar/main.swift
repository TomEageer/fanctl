// Fanctl menu bar app — localized (en/zh/ja/ko/es/fr/de/ru)
// Low-overhead by design: 15s refresh closed / 2s open; UI reads daemon status
// files only and never touches SMC directly.
import AppKit

let runDir      = "/usr/local/var/fanctl"
let statusPath  = runDir + "/status.json"
let historyPath = runDir + "/history.jsonl"
let cmdPath     = runDir + "/cmd/cmd"
let uninstallTool = "/usr/local/libexec/fanctl/uninstall.sh"
let daemonPlist = "/Library/LaunchDaemons/io.fanctl.daemon.plist"
let feedbackEmail = "tomeageer@gmail.com"
let websiteURL    = "https://tomeageer.com"
let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
var fanMin = 2000.0            // 由守护进程按机型探测后回填
var fanMax = 7826.0
var rpmAxisMax = 8000.0
var ffGain = 110.0             // 由守护进程回填：每瓦发热需要多少转速（回退用）
// 本机热模型（守护进程在线辨识）：散热功率 = (k0 + k1·rpm/1000) × (温度 − 环境温度)
struct ThermalModel { var k0: Double; var k1: Double; var tamb: Double; var n: Int }
var thermal: ThermalModel? = nil
func dissipation(rpm: Double, temp: Double) -> Double? {
    guard let m = thermal else { return nil }
    return max(0, (m.k0 + m.k1 * rpm / 1000) * (temp - m.tamb))
}

// MARK: - 本地化

let langOverrideKey = "uiLangOverride"
let uiLang: String = {
    if let pick = UserDefaults.standard.string(forKey: langOverrideKey) { return pick }
    let p = Locale.preferredLanguages.first ?? "en"
    for c in ["zh", "ja", "ko", "es", "fr", "de", "ru"] where p.hasPrefix(c) { return c }
    return "en"
}()
// (语言代码, 母语名) — nil 代表跟随系统
let langChoices: [(String?, String)] = [
    (nil, ""), ("en", "English"), ("zh", "简体中文"), ("ja", "日本語"), ("ko", "한국어"),
    ("es", "Español"), ("fr", "Français"), ("de", "Deutsch"), ("ru", "Русский"),
]

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
    "profile":      ["en": "Fan Profile", "zh": "调速性格", "ja": "制御プロファイル", "ko": "제어 프로파일",
                     "es": "Perfil", "fr": "Profil", "de": "Profil", "ru": "Профиль"],
    "pQuiet":       ["en": "Quiet", "zh": "安静", "ja": "静音", "ko": "조용함",
                     "es": "Silencioso", "fr": "Silencieux", "de": "Leise", "ru": "Тихий"],
    "pBalanced":    ["en": "Balanced", "zh": "均衡", "ja": "バランス", "ko": "균형",
                     "es": "Equilibrado", "fr": "Équilibré", "de": "Ausgewogen", "ru": "Баланс"],
    "pCool":        ["en": "Cool", "zh": "凉爽", "ja": "冷却重視", "ko": "시원함",
                     "es": "Frío", "fr": "Frais", "de": "Kühl", "ru": "Прохладный"],
    "installDone":  ["en": "Background service installed and running.", "zh": "后台服务已安装并运行。", "ja": "バックグラウンドサービスをインストールし実行中です。", "ko": "백그라운드 서비스가 설치되어 실행 중입니다.",
                     "es": "Servicio instalado y en ejecución.", "fr": "Service installé et en cours d'exécution.", "de": "Dienst installiert und aktiv.", "ru": "Служба установлена и работает."],
    "lgTemp":       ["en": "Temp", "zh": "温度", "ja": "温度", "ko": "온도",
                     "es": "Temp", "fr": "Temp", "de": "Temp", "ru": "Темп"],
    "lgCooling":    ["en": "Cooling", "zh": "散热", "ja": "放熱", "ko": "방열",
                     "es": "Disip.", "fr": "Dissip.", "de": "Kühlung", "ru": "Отвод"],
    "lgHeat":       ["en": "Heat", "zh": "产热", "ja": "発熱", "ko": "발열",
                     "es": "Calor", "fr": "Chaleur", "de": "Wärme", "ru": "Тепло"],
    "lgPower":      ["en": "Power", "zh": "功耗", "ja": "電力", "ko": "전력",
                     "es": "Cons.", "fr": "Conso", "de": "Leistung", "ru": "Мощн."],
    "lgRpm":        ["en": "RPM", "zh": "转速", "ja": "回転", "ko": "회전",
                     "es": "RPM", "fr": "RPM", "de": "U/min", "ru": "Об/м"],
    "lgSystem":     ["en": "System", "zh": "系统", "ja": "システム", "ko": "시스템",
                     "es": "Sistema", "fr": "Système", "de": "System", "ru": "Система"],
    "lgManual":     ["en": "Manual", "zh": "手动", "ja": "手動", "ko": "수동",
                     "es": "Manual", "fr": "Manuel", "de": "Manuell", "ru": "Ручной"],
    "heatIn":       ["en": "Heat produced", "zh": "产热量", "ja": "発熱量", "ko": "발열량",
                     "es": "Calor generado", "fr": "Chaleur produite", "de": "Wärmeerzeugung", "ru": "Тепловыделение"],
    "heatOut":      ["en": "Heat removed", "zh": "散热量", "ja": "放熱量", "ko": "방열량",
                     "es": "Calor disipado", "fr": "Chaleur évacuée", "de": "Wärmeabfuhr", "ru": "Теплоотвод"],
    "noData":       ["en": "—", "zh": "—", "ja": "—", "ko": "—", "es": "—", "fr": "—", "de": "—", "ru": "—"],
    "uninstall":    ["en": "Uninstall Fanctl…", "zh": "卸载 Fanctl…", "ja": "Fanctl をアンインストール…", "ko": "Fanctl 제거…",
                     "es": "Desinstalar Fanctl…", "fr": "Désinstaller Fanctl…", "de": "Fanctl deinstallieren…", "ru": "Удалить Fanctl…"],
    "uninstallMsg": ["en": "This removes the background service, restores system fan control, and deletes Fanctl.",
                     "zh": "将移除后台服务、把风扇交还系统控制，并删除 Fanctl。",
                     "ja": "バックグラウンドサービスを削除し、ファン制御をシステムに戻して Fanctl を削除します。",
                     "ko": "백그라운드 서비스를 제거하고 팬 제어를 시스템에 반환한 뒤 Fanctl을 삭제합니다.",
                     "es": "Elimina el servicio, devuelve el control del ventilador al sistema y borra Fanctl.",
                     "fr": "Supprime le service, rend le contrôle du ventilateur au système et efface Fanctl.",
                     "de": "Entfernt den Dienst, gibt die Lüftersteuerung ans System zurück und löscht Fanctl.",
                     "ru": "Удаляет службу, возвращает управление вентилятором системе и стирает Fanctl."],
    "cancel":       ["en": "Cancel", "zh": "取消", "ja": "キャンセル", "ko": "취소",
                     "es": "Cancelar", "fr": "Annuler", "de": "Abbrechen", "ru": "Отмена"],
    "updateAvail":  ["en": "Update to v%@", "zh": "更新到 v%@", "ja": "v%@ に更新", "ko": "v%@로 업데이트",
                     "es": "Actualizar a v%@", "fr": "Mettre à jour vers v%@", "de": "Auf v%@ aktualisieren", "ru": "Обновить до v%@"],
    "checkUpdate":  ["en": "Check for Updates…", "zh": "检查更新…", "ja": "アップデートを確認…", "ko": "업데이트 확인…",
                     "es": "Buscar actualizaciones…", "fr": "Rechercher des mises à jour…", "de": "Nach Updates suchen…", "ru": "Проверить обновления…"],
    "upToDate":     ["en": "You're up to date.", "zh": "已是最新版本。", "ja": "最新バージョンです。", "ko": "최신 버전입니다.",
                     "es": "Estás actualizado.", "fr": "Vous êtes à jour.", "de": "Auf dem neuesten Stand.", "ru": "У вас последняя версия."],
    "newVer":       ["en": "New version available", "zh": "发现新版本", "ja": "新しいバージョンがあります", "ko": "새 버전이 있습니다",
                     "es": "Nueva versión disponible", "fr": "Nouvelle version disponible", "de": "Neue Version verfügbar", "ru": "Доступна новая версия"],
    "updateNow":    ["en": "Update Now", "zh": "立即更新", "ja": "今すぐ更新", "ko": "지금 업데이트",
                     "es": "Actualizar ahora", "fr": "Mettre à jour", "de": "Jetzt aktualisieren", "ru": "Обновить"],
    "updDownloading": ["en": "Downloading", "zh": "下载中", "ja": "ダウンロード中", "ko": "다운로드 중",
                     "es": "Descargando", "fr": "Téléchargement", "de": "Wird geladen", "ru": "Загрузка"],
    "updExtract":   ["en": "Extracting…", "zh": "解压中…", "ja": "展開中…", "ko": "압축 해제 중…",
                     "es": "Extrayendo…", "fr": "Extraction…", "de": "Entpacken…", "ru": "Распаковка…"],
    "updAuth":      ["en": "Waiting for authorization…", "zh": "等待授权…", "ja": "認証を待機中…", "ko": "승인 대기 중…",
                     "es": "Esperando autorización…", "fr": "En attente d'autorisation…", "de": "Warte auf Autorisierung…", "ru": "Ожидание авторизации…"],
    "updRestart":   ["en": "Update complete, restarting…", "zh": "更新完成，正在重启…", "ja": "更新完了、再起動中…", "ko": "업데이트 완료, 다시 시작 중…",
                     "es": "Actualizado, reiniciando…", "fr": "Terminé, redémarrage…", "de": "Fertig, Neustart…", "ru": "Готово, перезапуск…"],
    "updFailed":    ["en": "Update failed — please download manually from GitHub Releases.", "zh": "更新失败，请到 GitHub Releases 手动下载。",
                     "ja": "更新に失敗しました。GitHub Releases から手動でダウンロードしてください。", "ko": "업데이트 실패 — GitHub Releases에서 수동으로 다운로드하세요.",
                     "es": "Error al actualizar: descargue manualmente desde GitHub Releases.", "fr": "Échec de la mise à jour — téléchargez manuellement depuis GitHub Releases.",
                     "de": "Update fehlgeschlagen — bitte manuell von GitHub Releases laden.", "ru": "Не удалось обновить — скачайте вручную из GitHub Releases."],
    "checkFailed":  ["en": "Could not check for updates (network).", "zh": "检查更新失败（网络问题）。", "ja": "更新を確認できません（ネットワーク）。", "ko": "업데이트 확인 실패(네트워크).",
                     "es": "No se pudo comprobar (red).", "fr": "Vérification impossible (réseau).", "de": "Prüfung fehlgeschlagen (Netzwerk).", "ru": "Не удалось проверить (сеть)."],
    "language":     ["en": "Language", "zh": "语言", "ja": "言語", "ko": "언어",
                     "es": "Idioma", "fr": "Langue", "de": "Sprache", "ru": "Язык"],
    "langSystem":   ["en": "System Default", "zh": "跟随系统", "ja": "システムに従う", "ko": "시스템 기본값",
                     "es": "Predeterminado del sistema", "fr": "Défaut du système", "de": "Systemstandard", "ru": "Как в системе"],
    "settings":     ["en": "Settings", "zh": "设置", "ja": "設定", "ko": "설정",
                     "es": "Ajustes", "fr": "Réglages", "de": "Einstellungen", "ru": "Настройки"],
    "loginStart":   ["en": "Launch Fanctl at login", "zh": "登录时自动启动 Fanctl", "ja": "ログイン時に Fanctl を起動", "ko": "로그인 시 Fanctl 시작",
                     "es": "Iniciar Fanctl al iniciar sesión", "fr": "Lancer Fanctl à la connexion", "de": "Fanctl beim Anmelden starten", "ru": "Запускать Fanctl при входе"],
    "showPower":    ["en": "Show power in menu bar", "zh": "菜单栏同时显示功耗", "ja": "メニューバーに消費電力も表示", "ko": "메뉴 막대에 전력도 표시",
                     "es": "Mostrar consumo en la barra", "fr": "Afficher la consommation dans la barre", "de": "Leistung in Menüleiste anzeigen", "ru": "Показывать мощность в строке меню"],
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

struct Sample { let ts, temp: Double; let rpm: Double; let w: Double; let mode: String; let pf: String }

func modeColor(_ mode: String) -> NSColor {
    switch mode {
    case "manual":  return .systemBlue
    case "custom":  return .systemOrange
    case "battery": return .systemGreen
    default:        return .systemGray
    }
}

func profileName(_ pf: String) -> String {
    switch pf {
    case "quiet": return T("pQuiet")
    case "cool":  return T("pCool")
    default:      return T("pBalanced")
    }
}

func modeName(_ mode: String, rpm: Double, profile: String = "balanced") -> String {
    switch mode {
    case "manual":  return T("smart") + " · " + profileName(profile)
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

    private let padL: CGFloat = 42, padR: CGFloat = 36, padT: CGFloat = 26, padB: CGFloat = 56

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
                          w: (o["w"] as? NSNumber)?.doubleValue ?? 0,
                          mode: o["mode"] as? String ?? "auto",
                          pf: o["pf"] as? String ?? "balanced")
        }
        // 时间戳必须单调：并发写入/文件修剪可能造成乱序，排序去重后再绘制，
        // 否则样条会出现"向后回勾"的非物理曲线
        samples.sort { $0.ts < $1.ts }
        var dedup: [Sample] = []
        for smp in samples where dedup.last.map({ smp.ts > $0.ts }) ?? true {
            dedup.append(smp)
        }
        samples = smoothed(dedup, window: 9)
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
            let p = raw[a...b].reduce(0.0) { $0 + $1.w } / n
            return Sample(ts: s.ts, temp: t, rpm: r, w: p, mode: s.mode, pf: s.pf)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.saveGraphicsState()
        let plot = NSRect(x: padL, y: padB, width: bounds.width - padL - padR,
                          height: bounds.height - padT - padB)
        let title = windowOptions.first { $0.1 == windowSec }?.0 ?? ""
        drawText(T("chartTitle"),
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
        lo = max(lo, 20); hi = min(hi, 110)
        if hi - lo < 15 { hi = min(110, lo + 15); lo = hi - 15 }   // 钳位后再保证跨度，防除零

        func px(_ ts: Double) -> CGFloat { plot.minX + CGFloat((ts - t0) / (now - t0)) * plot.width }
        func pyT(_ v: Double) -> CGFloat { plot.minY + CGFloat((v - lo) / (hi - lo)) * plot.height }
        func pyR(_ v: Double) -> CGFloat { plot.minY + CGFloat(v / rpmAxisMax) * plot.height }
        // 瓦特轴：模型就绪后产热/散热同轴直接比较（散热>产热即降温）
        let wMax: Double = {
            guard thermal != nil else { return 60 }
            let peak = samples.map { max($0.w, dissipation(rpm: $0.rpm, temp: $0.temp) ?? 0) }.max() ?? 60
            return max(20, (peak / 10).rounded(.up) * 10)
        }()
        func pyWatt(_ v: Double) -> CGFloat { plot.minY + CGFloat(min(v, wMax) / wMax) * plot.height }
        func pyW(_ v: Double) -> CGFloat { pyR(min(fanMin + max(0, v - 8) * ffGain, rpmAxisMax)) }

        func bandColor(_ s: Sample) -> NSColor {
            if s.mode == "manual" {
                switch s.pf {                       // 智能调速按性格分深浅
                case "quiet": return NSColor.systemBlue.withAlphaComponent(0.07)
                case "cool":  return NSColor.systemBlue.withAlphaComponent(0.28)
                default:      return NSColor.systemBlue.withAlphaComponent(0.15)
                }
            }
            return modeColor(s.mode).withAlphaComponent(0.15)
        }
        var i = 0
        while i < samples.count {
            var j = i
            while j + 1 < samples.count && samples[j + 1].mode == samples[i].mode
                  && samples[j + 1].pf == samples[i].pf { j += 1 }
            let x1 = px(samples[i].ts), x2 = max(px(samples[j].ts), x1 + 1)
            bandColor(samples[i]).setFill()
            NSRect(x: x1, y: plot.minY, width: x2 - x1, height: plot.height).fill()
            i = j + 1
        }

        NSColor.separatorColor.setStroke()
        for temp in stride(from: lo, through: hi, by: 10) {
            let g = NSBezierPath(); g.lineWidth = 0.5
            g.move(to: NSPoint(x: plot.minX, y: pyT(temp)))
            g.line(to: NSPoint(x: plot.maxX, y: pyT(temp)))
            g.stroke()
            drawText("\(Int(temp))°", at: NSPoint(x: 12, y: pyT(temp) - 5), size: 9, color: .secondaryLabelColor)
        }
        if thermal != nil {
            for f in [0.0, 0.5, 1.0] {
                drawText(String(format: "%.0fW", wMax * f),
                         at: NSPoint(x: plot.maxX + 5, y: pyWatt(wMax * f) - 5), size: 9,
                         color: NSColor.systemTeal.withAlphaComponent(0.9))
            }
        } else {
            for rpm in [0.0, 4000.0, 8000.0] {
                drawText(rpm == 0 ? "0" : String(format: "%.0fk", rpm / 1000),
                         at: NSPoint(x: plot.maxX + 5, y: pyR(rpm) - 5), size: 9,
                         color: NSColor.systemTeal.withAlphaComponent(0.9))
            }
        }
        drawText("-" + title, at: NSPoint(x: plot.minX, y: padB - 12), size: 9, color: .tertiaryLabelColor)
        drawText(T("now"), at: NSPoint(x: plot.maxX - 34, y: padB - 12), size: 9, color: .tertiaryLabelColor)

        NSBezierPath(rect: plot).setClip()          // 曲线不越界画到图例/标题上
        if thermal != nil {
            // 产热（紫虚线）与散热（青实线）同为瓦特：青线在上 = 正在降温
            NSColor.systemPurple.withAlphaComponent(0.85).setStroke()
            strokeSeries(samples.map { (px($0.ts), pyWatt($0.w), $0.ts) }, lineWidth: 1.0, dashed: true)
            NSColor.systemTeal.setStroke()
            strokeSeries(samples.compactMap { s in
                dissipation(rpm: s.rpm, temp: s.temp).map { (px(s.ts), pyWatt($0), s.ts) }
            }, lineWidth: 1.2)
        } else {
            if samples.contains(where: { $0.w > 0 }) {
                NSColor.systemPurple.withAlphaComponent(0.85).setStroke()
                strokeSeries(samples.map { (px($0.ts), pyW($0.w), $0.ts) }, lineWidth: 1.0, dashed: true)
            }
            NSColor.systemTeal.setStroke()
            strokeSeries(samples.map { (px($0.ts), pyR($0.rpm), $0.ts) }, lineWidth: 1.0)
        }

        NSColor.labelColor.setStroke()
        strokeSeries(samples.map { (px($0.ts), pyT($0.temp), $0.ts) }, lineWidth: 1.6)
        NSGraphicsContext.current?.restoreGraphicsState()
        NSGraphicsContext.current?.saveGraphicsState()
    }

    /// 按采样间隔切分连续段：数据缺失处留断口，不用直线跨接假装连续
    private func runs(_ pts: [(x: CGFloat, y: CGFloat, ts: Double)]) -> [[NSPoint]] {
        var out: [[NSPoint]] = []
        var cur: [NSPoint] = []
        var lastTs: Double? = nil
        for p in pts {
            if let l = lastTs, p.ts - l > 20 {      // 超过 20 秒无样本视为断开
                if cur.count > 1 { out.append(cur) }
                cur = []
            }
            cur.append(NSPoint(x: p.x, y: p.y))
            lastTs = p.ts
        }
        if cur.count > 1 { out.append(cur) }
        return out
    }

    private func strokeSeries(_ pts: [(x: CGFloat, y: CGFloat, ts: Double)],
                              lineWidth: CGFloat, dashed: Bool = false) {
        for seg in runs(pts) {
            let p = splinePath(seg, lineWidth: lineWidth)
            if dashed { p.setLineDash([4, 3], count: 2, phase: 0) }
            p.stroke()
        }
    }

    /// 抽稀 + 向心参数化 Catmull-Rom 样条。
    /// 均匀参数化在数据剧变处（例如读数中断造成的近垂直跳变）会过冲并自交，
    /// 表现为曲线"向后回勾"；向心参数化（α=0.5）在数学上保证无尖点、无自交。
    private func splinePath(_ raw: [NSPoint], lineWidth: CGFloat) -> NSBezierPath {
        var pts = raw
        let maxPts = max(4, Int(bounds.width / 2.5))
        if pts.count > maxPts {
            let step = Double(pts.count) / Double(maxPts)
            pts = (0..<maxPts).map { raw[min(raw.count - 1, Int(Double($0) * step))] }
            if let last = raw.last, pts.last != last { pts.append(last) }
        }
        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        guard pts.count > 2 else {
            if let f = pts.first {
                path.move(to: f)
                for p in pts.dropFirst() { path.line(to: p) }
            }
            return path
        }

        func dist(_ a: NSPoint, _ b: NSPoint) -> CGFloat {
            max(sqrt(pow(b.x - a.x, 2) + pow(b.y - a.y, 2)), 1e-4)
        }

        path.move(to: pts[0])
        for i in 0..<(pts.count - 1) {
            let p0 = i > 0 ? pts[i - 1] : pts[i]
            let p1 = pts[i], p2 = pts[i + 1]
            let p3 = i + 2 < pts.count ? pts[i + 2] : p2
            // 向心参数化：结点间距取欧氏距离的 0.5 次幂
            let d1 = pow(dist(p0, p1), 0.5)
            let d2 = pow(dist(p1, p2), 0.5)
            let d3 = pow(dist(p2, p3), 0.5)
            var c1 = NSPoint(x: p1.x + (p2.x - p1.x) / 3, y: p1.y + (p2.y - p1.y) / 3)
            var c2 = NSPoint(x: p2.x - (p2.x - p1.x) / 3, y: p2.y - (p2.y - p1.y) / 3)
            let k1 = 3 * d1 * (d1 + d2), k2 = 3 * d3 * (d3 + d2)
            if k1 > 1e-6 {
                c1 = NSPoint(
                    x: (d1 * d1 * p2.x - d2 * d2 * p0.x + (2 * d1 * d1 + 3 * d1 * d2 + d2 * d2) * p1.x) / k1,
                    y: (d1 * d1 * p2.y - d2 * d2 * p0.y + (2 * d1 * d1 + 3 * d1 * d2 + d2 * d2) * p1.y) / k1)
            }
            if k2 > 1e-6 {
                c2 = NSPoint(
                    x: (d3 * d3 * p1.x - d2 * d2 * p3.x + (2 * d3 * d3 + 3 * d3 * d2 + d2 * d2) * p2.x) / k2,
                    y: (d3 * d3 * p1.y - d2 * d2 * p3.y + (2 * d3 * d3 + 3 * d3 * d2 + d2 * d2) * p2.y) / k2)
            }
            // 兜底：控制点的 x 必须落在区段内，杜绝任何情况下的时间轴回退
            c1.x = min(max(c1.x, p1.x), p2.x)
            c2.x = min(max(c2.x, p1.x), p2.x)
            path.curve(to: p2, controlPoint1: c1, controlPoint2: c2)
        }
        return path
    }

    private func drawLegend() {
        let f = NSFont.systemFont(ofSize: 9)
        func w(_ t: String) -> CGFloat { t.size(withAttributes: [.font: f]).width }

        // 上行：背景底纹代表的运行模式
        let dots: [(NSColor, String)] = [
            (NSColor.systemBlue.withAlphaComponent(0.30), T("pQuiet")),
            (NSColor.systemBlue.withAlphaComponent(0.60), T("pBalanced")),
            (NSColor.systemBlue, T("pCool")),
            (.systemOrange, T("lgManual")),
            (.systemGray, T("lgSystem")),
        ]
        let dotsWidth = dots.reduce(0) { $0 + 7 + 4 + w($1.1) }
        var gap = max(6, min(14, (bounds.width - padL - 6 - dotsWidth) / CGFloat(dots.count - 1)))
        var x = padL
        for (c, name) in dots {
            c.setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: 21, width: 7, height: 7)).fill()
            drawText(name, at: NSPoint(x: x + 11, y: 18), size: 9, color: .secondaryLabelColor)
            x += 7 + 4 + w(name) + gap
        }

        // 下行：三条曲线的线型
        let lines: [(NSColor, String, Bool)] = [
            (.labelColor, T("lgTemp"), false),
            (.systemTeal, thermal != nil ? T("lgCooling") : T("lgRpm"), false),
            (NSColor.systemPurple.withAlphaComponent(0.85),
             thermal != nil ? T("lgHeat") : T("lgPower"), true),
        ]
        let linesWidth = lines.reduce(0) { $0 + 14 + 4 + w($1.1) }
        gap = max(10, min(24, (bounds.width - padL - 6 - linesWidth) / CGFloat(lines.count - 1)))
        x = padL
        for (c, name, dashed) in lines {
            c.setStroke()
            let seg = NSBezierPath()
            seg.lineWidth = 2
            if dashed { seg.setLineDash([4, 3], count: 2, phase: 0) }
            seg.move(to: NSPoint(x: x, y: 7)); seg.line(to: NSPoint(x: x + 14, y: 7))
            seg.stroke()
            drawText(name, at: NSPoint(x: x + 18, y: 3), size: 9, color: .secondaryLabelColor)
            x += 14 + 4 + w(name) + gap
        }
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
    let chart = ChartView(frame: NSRect(x: 24, y: 96, width: 340, height: 196))
    let speedLabel = NSTextField(labelWithString: "--")
    let speed = SpeedControlView(frame: NSRect(x: 24, y: 362, width: 340, height: 24))
    var smartPop: NSPopUpButton!
    let loginBox = NSButton(checkboxWithTitle: T("loginStart"), target: nil, action: nil)
    let iconBox  = NSButton(checkboxWithTitle: T("showIcon"), target: nil, action: nil)
    let powerBox = NSButton(checkboxWithTitle: T("showPower"), target: nil, action: nil)
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
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 388, height: 686),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Fanctl"
        if #available(macOS 11.0, *) { window.subtitle = "v\(appVersion)" }
        window.isReleasedWhenClosed = false
        window.delegate = self
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: 388, height: 686))

        tempBig.font = .monospacedDigitSystemFont(ofSize: 40, weight: .semibold)
        tempBig.frame = NSRect(x: 24, y: 16, width: 260, height: 48)
        root.addSubview(tempBig)
        subLine.font = .systemFont(ofSize: 13)
        subLine.textColor = .secondaryLabelColor
        subLine.frame = NSRect(x: 26, y: 64, width: 340, height: 18)
        root.addSubview(subLine)

        root.addSubview(chart)

        root.addSubview(separator(y: 306))
        root.addSubview(sectionLabel(T("fanSpeed"), y: 318))
        speedLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        speedLabel.frame = NSRect(x: 24, y: 336, width: 340, height: 20)
        root.addSubview(speedLabel)
        speed.onDrag = { [weak self] rpm in
            self?.speedLabel.stringValue = "\(rpm) RPM · \(T("manual"))（\(T("releaseApply"))）"
        }
        speed.onPick = { [weak self] rpm in
            self?.app?.writeCmd("set \(rpm)")
            self?.speedLabel.stringValue = "\(rpm) RPM · \(T("manual"))"
        }
        root.addSubview(speed)

        let bw: CGFloat = (340 - 16) / 3
        smartPop = NSPopUpButton(frame: NSRect(x: 24, y: 402, width: bw + 14, height: 32), pullsDown: true)
        smartPop.addItem(withTitle: T("smart"))
        for (code, key) in [("quiet", "pQuiet"), ("balanced", "pBalanced"), ("cool", "pCool")] {
            smartPop.addItem(withTitle: T(key))
            smartPop.lastItem?.representedObject = code
            smartPop.lastItem?.target = self
            smartPop.lastItem?.action = #selector(panelPickProfile(_:))
        }
        root.addSubview(smartPop)
        for (i, (title, verb)) in [(T("maxSpeed"), "max"), (T("restoreSys"), "pause")].enumerated() {
            let b = NSButton(title: title, target: self, action: #selector(modeButton(_:)))
            b.bezelStyle = .rounded
            b.controlSize = .large
            b.font = .systemFont(ofSize: 12)
            b.identifier = NSUserInterfaceItemIdentifier(verb)
            b.frame = NSRect(x: 24 + 14 + CGFloat(i + 1) * (bw + 8), y: 402, width: bw - 7, height: 32)
            root.addSubview(b)
        }

        root.addSubview(separator(y: 444))
        root.addSubview(sectionLabel(T("settings"), y: 446))
        loginBox.frame = NSRect(x: 24, y: 478, width: 340, height: 20)
        loginBox.target = self; loginBox.action = #selector(toggleLogin)
        iconBox.frame = NSRect(x: 24, y: 502, width: 340, height: 20)
        iconBox.target = self; iconBox.action = #selector(toggleIcon)
        powerBox.frame = NSRect(x: 24, y: 526, width: 340, height: 20)
        powerBox.target = self; powerBox.action = #selector(togglePower)
        root.addSubview(loginBox)
        root.addSubview(iconBox)
        root.addSubview(powerBox)
        let langLabel = NSTextField(labelWithString: "🌐 " + T("language"))
        langLabel.font = .systemFont(ofSize: 13)
        langLabel.frame = NSRect(x: 24, y: 554, width: 110, height: 20)
        root.addSubview(langLabel)
        let pop = NSPopUpButton(frame: NSRect(x: 138, y: 550, width: 226, height: 26))
        let current = UserDefaults.standard.string(forKey: langOverrideKey)
        for (code, name) in langChoices {
            pop.addItem(withTitle: code == nil ? T("langSystem") : name)
            pop.lastItem?.representedObject = code as Any?
            if code == current { pop.select(pop.lastItem) }
        }
        pop.target = self
        pop.action = #selector(pickLangPopup(_:))
        root.addSubview(pop)

        let hint = NSTextField(wrappingLabelWithString: T("hint"))
        hint.frame = NSRect(x: 24, y: 582, width: 340, height: 44)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        root.addSubview(hint)

        let mail = NSButton(title: "✉ \(feedbackEmail)", target: self, action: #selector(openMail))
        mail.isBordered = false
        mail.contentTintColor = .linkColor
        mail.font = .systemFont(ofSize: 11)
        mail.frame = NSRect(x: 20, y: 630, width: 200, height: 18)
        let site = NSButton(title: "🌐 tomeageer.com", target: self, action: #selector(openSite))
        site.isBordered = false
        site.contentTintColor = .linkColor
        site.font = .systemFont(ofSize: 11)
        site.frame = NSRect(x: 228, y: 630, width: 140, height: 18)
        root.addSubview(mail)
        root.addSubview(site)

        let ver = NSTextField(labelWithString: "Fanctl v\(appVersion)")
        ver.font = .systemFont(ofSize: 11)
        ver.textColor = .tertiaryLabelColor
        ver.frame = NSRect(x: 24, y: 656, width: 150, height: 16)
        root.addSubview(ver)
        let upd = NSButton(title: T("checkUpdate"), target: self, action: #selector(checkUpd))
        upd.isBordered = false
        upd.contentTintColor = .linkColor
        upd.font = .systemFont(ofSize: 11)
        upd.frame = NSRect(x: 228, y: 654, width: 140, height: 18)
        root.addSubview(upd)

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
        powerBox.state = AppDelegate.showPowerInBar() ? .on : .off
    }

    @objc func modeButton(_ sender: NSButton) {
        if let verb = sender.identifier?.rawValue { app?.writeCmd(verb) }
    }

    @objc func toggleLogin() { AppDelegate.setLaunchAtLogin(loginBox.state == .on) }

    @objc func toggleIcon() {
        UserDefaults.standard.set(iconBox.state == .on, forKey: "showMenuIcon")
        app?.applyMenuIconVisibility()
    }

    @objc func togglePower() {
        UserDefaults.standard.set(powerBox.state == .on, forKey: "showPowerInBar")
        app?.lastTitle = ""      // 强制下轮重绘
        app?.refresh()
    }

    @objc func panelPickProfile(_ sender: NSMenuItem) {
        if let code = sender.representedObject as? String { app?.writeCmd("profile \(code)") }
    }

    @objc func pickLangPopup(_ sender: NSPopUpButton) {
        app?.applyLanguage(sender.selectedItem?.representedObject as? String)
    }

    @objc func checkUpd() { app?.checkUpdates(interactive: true) }

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
        let tempOpt  = (j["temp"]  as? NSNumber)?.doubleValue
        let powerOpt = (j["power"] as? NSNumber)?.doubleValue
        let rpm   = (j["rpm"]   as? NSNumber)?.doubleValue ?? 0
        let act   = (j["act"]   as? NSNumber)?.doubleValue ?? rpm
        let mode  = j["mode"] as? String ?? "?"
        tempBig.stringValue = tempOpt.map { String(format: "%.1f °C", $0) } ?? T("noData")
        let profNow = j["profile"] as? String ?? "balanced"
        subLine.stringValue = (powerOpt.map { String(format: "%.1f W · ", $0) } ?? "")
            + modeName(mode, rpm: rpm, profile: profNow)
            + ((j["err"] as? String).map { "  ⚠️ " + $0 } ?? "")
        for item in smartPop.itemArray.dropFirst() {
            item.state = ((item.representedObject as? String) == profNow) ? .on : .off
        }
        if !speed.dragging {
            speed.actual = act > 0 ? act : fanMin
            speed.setpoint = (mode == "custom") ? rpm : nil
            speed.needsDisplay = true
            speedLabel.stringValue = (j["act"] as? NSNumber).map { "\($0.intValue) RPM" } ?? T("noData")
        }
    }
}

// MARK: - 更新器（GitHub Releases 原生，无第三方依赖）

enum Updater {
    static let api = "https://api.github.com/repos/TomEageer/fanctl/releases/latest"
    static let assetURL = "https://github.com/TomEageer/fanctl/releases/latest/download/Fanctl.zip"

    static func fetchLatest(_ done: @escaping (String?) -> Void) {
        guard let url = URL(string: api) else { done(nil); return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, _, _ in
            var tag: String?
            if let d = data,
               let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let t = j["tag_name"] as? String {
                tag = t.hasPrefix("v") ? String(t.dropFirst()) : t
            }
            DispatchQueue.main.async { done(tag) }
        }.resume()
    }

    static func isNewer(_ remote: String, than local: String) -> Bool {
        let r = remote.split(separator: ".").map { Int($0) ?? 0 }
        let l = local.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(r.count, l.count) {
            let a = i < r.count ? r[i] : 0
            let b = i < l.count ? l[i] : 0
            if a != b { return a > b }
        }
        return false
    }

}

// MARK: - 更新进度窗口（下载百分比 → 解压 → 授权 → 重启）

final class UpdateProgressController: NSObject, URLSessionDownloadDelegate {
    static var active: UpdateProgressController?      // 保活 + 防重入
    private var session: URLSession?
    private var cancelled = false
    private let window: NSWindow
    private let bar = NSProgressIndicator(frame: NSRect(x: 20, y: 34, width: 280, height: 16))
    private let label = NSTextField(labelWithString: "…")
    private let onFail: () -> Void
    private let tmp = NSTemporaryDirectory() + "fanctl-update"

    init(onFail: @escaping () -> Void) {
        self.onFail = onFail
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 92),
                          styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        window.title = "Fanctl"
        window.level = .floating
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 92))
        label.frame = NSRect(x: 20, y: 58, width: 280, height: 18)
        label.font = .systemFont(ofSize: 12)
        bar.minValue = 0
        bar.maxValue = 100
        bar.isIndeterminate = false
        let cancel = NSButton(title: T("cancel"), target: self, action: #selector(cancelUpdate))
        cancel.bezelStyle = .rounded
        cancel.frame = NSRect(x: 228, y: 2, width: 76, height: 28)
        root.addSubview(cancel)
        root.addSubview(label)
        root.addSubview(bar)
        window.contentView = root
        window.center()
    }

    func start() {
        guard UpdateProgressController.active == nil else { return }
        UpdateProgressController.active = self
        label.stringValue = T("updDownloading") + " 0%"
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try? FileManager.default.removeItem(atPath: tmp)
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session = s
        s.downloadTask(with: URL(string: Updater.assetURL)!).resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite total: Int64) {
        guard total > 0 else { return }
        let pct = Double(totalBytesWritten) / Double(total) * 100
        DispatchQueue.main.async {
            self.bar.doubleValue = pct
            self.label.stringValue = T("updDownloading") + String(format: " %.0f%%", pct)
        }
    }

    @objc func cancelUpdate() {
        cancelled = true
        session?.invalidateAndCancel()
        session = nil
        window.orderOut(nil)
        UpdateProgressController.active = nil
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        if cancelled { return }
        let zip = tmp + "/Fanctl.zip"
        try? FileManager.default.moveItem(at: location, to: URL(fileURLWithPath: zip))
        DispatchQueue.main.async {
            self.bar.isIndeterminate = true
            self.bar.startAnimation(nil)
            self.label.stringValue = T("updExtract")
        }
        let un = Process()
        un.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        un.arguments = ["-x", "-k", zip, tmp]
        try? un.run()
        un.waitUntilExit()
        let ok = un.terminationStatus == 0 && FileManager.default.fileExists(atPath: tmp + "/Fanctl.app")
        DispatchQueue.main.async {
            guard ok else { self.finish(failed: true); return }
            self.label.stringValue = T("updAuth")
            let priv = "rm -rf /Applications/Fanctl.app && cp -R '\(self.tmp)/Fanctl.app' /Applications/ && /bin/bash '/Applications/Fanctl.app/Contents/Resources/install-helper.sh' '/Applications/Fanctl.app/Contents/Resources' && rm -rf '\(self.tmp)'"
            let osa = "do shell script \"\(priv.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
            var err: NSDictionary?
            NSAppleScript(source: osa)?.executeAndReturnError(&err)
            if let err {
                self.finish(failed: (err["NSAppleScriptErrorNumber"] as? Int) != -128)
                return
            }
            self.label.stringValue = T("updRestart")
            self.session?.finishTasksAndInvalidate()
            self.session = nil
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "sleep 1; open -n '\(Bundle.main.bundlePath)'"]
            try? p.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { NSApp.terminate(nil) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil && !cancelled {
            DispatchQueue.main.async { self.finish(failed: true) }
        }
    }

    private func finish(failed: Bool) {
        session?.finishTasksAndInvalidate()      // 不 invalidate 则 session 强引用 delegate 永不释放
        session = nil
        window.orderOut(nil)
        UpdateProgressController.active = nil
        if failed { onFail() }
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
            <key>ProgramArguments</key><array><string>\(Bundle.main.bundlePath)/Contents/MacOS/fanctl-bar</string></array>
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
    var profileItems: [String: NSMenuItem] = [:]
    var updItem: NSMenuItem!
    var speedLabel: NSTextField!
    let speedControl = SpeedControlView(frame: NSRect(x: 14, y: 2, width: 292, height: 24))
    let chart = ChartView(frame: NSRect(x: 0, y: 0, width: 320, height: 186))

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
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 48))
        speedLabel = NSTextField(labelWithString: T("rpm"))
        speedLabel.font = .menuFont(ofSize: 13)
        speedLabel.frame = NSRect(x: 14, y: 27, width: 292, height: 18)
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

        smartItem = NSMenuItem(title: T("smart"), action: nil, keyEquivalent: "")
        let profMenu = NSMenu()
        for (code, key) in [("quiet", "pQuiet"), ("balanced", "pBalanced"), ("cool", "pCool")] {
            let m = NSMenuItem(title: T(key), action: #selector(pickProfile(_:)), keyEquivalent: "")
            m.target = self
            m.representedObject = code
            profMenu.addItem(m)
            profileItems[code] = m
        }
        smartItem.submenu = profMenu
        fullItem  = makeItem(T("maxSpeed"), #selector(cmdMax))
        pauseItem = makeItem(T("restoreSys"), #selector(cmdPause))
        menu.addItem(smartItem)
        menu.addItem(fullItem)
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        menu.addItem(makeItem(T("panel"), #selector(openPanel)))
        menu.addItem(.separator())
        let langItem = NSMenuItem(title: "🌐 " + T("language"), action: nil, keyEquivalent: "")
        let langMenu = NSMenu()
        let current = UserDefaults.standard.string(forKey: langOverrideKey)
        for (code, name) in langChoices {
            let m = NSMenuItem(title: code == nil ? T("langSystem") : name,
                               action: #selector(pickLang(_:)), keyEquivalent: "")
            m.target = self
            m.representedObject = code as Any?
            m.state = (code == current) ? .on : .off
            langMenu.addItem(m)
            if code == nil { langMenu.addItem(.separator()) }
        }
        langItem.submenu = langMenu
        menu.addItem(langItem)
        let svcItem = makeItem("⚙️ " + T("installSvc"), #selector(installService))
        menu.addItem(svcItem)
        updItem = makeItem("🔄 " + T("checkUpdate"), #selector(menuCheckUpdate))
        menu.addItem(updItem)
        let fbItem = makeItem("✉️ " + T("feedback"), #selector(openFeedback))
        menu.addItem(fbItem)
        menu.addItem(makeItem("🗑️ " + T("uninstall"), #selector(uninstallApp)))
        menu.addItem(.separator())
        menu.addItem(makeItem(T("quit"), #selector(quit)))
        item.menu = menu

        refresh()
        slowTimer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(slowTimer!, forMode: .common)

        buildMainMenu()
        applyMenuIconVisibility()
        if !FileManager.default.fileExists(atPath: daemonPlist) {
            promptInstall(firstRun: true)
        }
        // 每日一次静默自动检查
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        if Date().timeIntervalSince1970 - last > 86400 {
            checkUpdates(interactive: false)
        }
    }

    /// 顶栏左侧应用主菜单（程序坞模式/面板聚焦时可见）：版本 + 检查更新 + 退出
    func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        let ver = NSMenuItem(title: "Fanctl v\(appVersion)", action: nil, keyEquivalent: "")
        ver.isEnabled = false
        appMenu.addItem(ver)
        appMenu.addItem(.separator())
        let upd = NSMenuItem(title: T("checkUpdate"), action: #selector(menuCheckUpdate), keyEquivalent: "")
        upd.target = self
        appMenu.addItem(upd)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: T("quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = main
    }

    @objc func menuCheckUpdate() { checkUpdates(interactive: true) }

    func checkUpdates(interactive: Bool) {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
        Updater.fetchLatest { [weak self] tag in
            guard let self else { return }
            guard let tag else {
                if interactive { self.simpleAlert(T("checkFailed")) }
                return
            }
            if Updater.isNewer(tag, than: appVersion) {
                self.updItem?.title = String(format: T("updateAvail"), tag)
                guard interactive else { return }      // 静默检查只改菜单标题，不抢焦点弹框
                let a = NSAlert()
                a.messageText = "\(T("newVer"))：v\(tag)"
                a.informativeText = "Fanctl v\(appVersion) → v\(tag)"
                a.addButton(withTitle: T("updateNow"))
                a.addButton(withTitle: T("laterBtn"))
                if a.runModal() == .alertFirstButtonReturn {
                    UpdateProgressController(onFail: { self.simpleAlert(T("updFailed")) }).start()
                }
            } else if interactive {
                self.simpleAlert("\(T("upToDate"))（v\(appVersion)）")
            }
        }
    }

    func simpleAlert(_ msg: String) {
        let a = NSAlert()
        a.messageText = "Fanctl"
        a.informativeText = msg
        a.runModal()
    }

    @objc func openPanel() { panel.show() }

    @objc func pickProfile(_ sender: NSMenuItem) {
        if let code = sender.representedObject as? String { writeCmd("profile \(code)") }
    }

    @objc func pickLang(_ sender: NSMenuItem) {
        applyLanguage(sender.representedObject as? String)
    }

    func applyLanguage(_ code: String?) {
        if let code {
            UserDefaults.standard.set(code, forKey: langOverrideKey)
        } else {
            UserDefaults.standard.removeObject(forKey: langOverrideKey)
        }
        UserDefaults.standard.synchronize()
        // 界面语言在启动时固化，切换后自动重启应用生效
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; open -n '\(Bundle.main.bundlePath)'"]
        try? p.run()
        NSApp.terminate(nil)
    }

    @objc func uninstallApp() {
        let a = NSAlert()
        a.messageText = T("uninstall")
        a.informativeText = T("uninstallMsg")
        a.alertStyle = .warning
        a.addButton(withTitle: T("uninstall"))
        a.addButton(withTitle: T("cancel"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let script = "do shell script \"/bin/bash '\(uninstallTool)'\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        if err == nil { NSApp.terminate(nil) }
        else if (err?["NSAppleScriptErrorNumber"] as? Int) != -128 { simpleAlert(T("updFailed")) }
    }

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
        if let err {
            // -128 = 用户在密码框点了取消，不算错误，静默返回
            if (err["NSAppleScriptErrorNumber"] as? Int) == -128 { return }
            let fail = NSAlert()
            fail.messageText = T("failTitle")
            fail.informativeText = T("failMsg")
            fail.runModal()
        } else {
            simpleAlert(T("installDone"))
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
            setBarText(temp: 0, power: 0, stale: true)
            modeRow.title = "\(T("runMode"))　\(T("svcDown"))"
            return
        }
        let tempOpt  = (j["temp"]  as? NSNumber)?.doubleValue     // 电池模式为 null
        let powerOpt = (j["power"] as? NSNumber)?.doubleValue
        let rpm   = (j["rpm"]   as? NSNumber)?.doubleValue ?? 0
        let actOpt = (j["act"]  as? NSNumber)?.doubleValue
        let act   = actOpt ?? 0
        let ts    = (j["ts"]    as? NSNumber)?.doubleValue ?? 0
        let mode  = j["mode"] as? String ?? "?"
        let stale = Date().timeIntervalSince1970 - ts > 90 || tempOpt == nil
        if let g = (j["ffGain"] as? NSNumber)?.doubleValue, g > 1 { ffGain = g }
        if let tm = j["thermal"] as? [String: Any],
           let k0 = (tm["k0"] as? NSNumber)?.doubleValue,
           let k1 = (tm["k1"] as? NSNumber)?.doubleValue,
           let ta = (tm["tamb"] as? NSNumber)?.doubleValue {
            thermal = ThermalModel(k0: k0, k1: k1, tamb: ta, n: (tm["n"] as? NSNumber)?.intValue ?? 0)
        } else if j["thermal"] is NSNull { thermal = nil }
        if let mn = (j["fanMin"] as? NSNumber)?.doubleValue,
           let mx = (j["fanMax"] as? NSNumber)?.doubleValue, mx > mn {
            fanMin = mn; fanMax = mx; rpmAxisMax = (mx / 1000).rounded(.up) * 1000
        }
        let temp = tempOpt ?? 0, power = powerOpt ?? 0

        setBarText(temp: temp, power: power, stale: stale)
        tempRow.title  = T("cpuTemp") + "　" + (tempOpt.map { String(format: "%.1f °C", $0) } ?? T("noData"))
            + ((j["ts"] != nil && Date().timeIntervalSince1970 - ts > 90) ? T("stale") : "")
        powerRow.title = T("sysPower") + "　" + (powerOpt.map { String(format: "%.1f W", $0) } ?? T("noData"))
        if let e = j["err"] as? String { modeRow.title = "⚠️ " + e }
        let profNow0 = j["profile"] as? String ?? "balanced"
        if j["err"] == nil || j["err"] is NSNull {
            modeRow.title = "\(T("runMode"))　" + modeName(mode, rpm: rpm, profile: profNow0)
        }

        smartItem.state = (mode == "manual" || mode == "auto") ? .on : .off
        pauseItem.state = (mode == "paused") ? .on : .off
        fullItem.state  = (mode == "custom" && rpm >= fanMax - 50) ? .on : .off
        let profNow = j["profile"] as? String ?? "balanced"
        for (code, m) in profileItems { m.state = (code == profNow) ? .on : .off }

        if !speedControl.dragging {
            speedControl.actual = act > 0 ? act : fanMin
            speedControl.setpoint = (mode == "custom") ? rpm : nil
            speedControl.isEnabled = (mode != "battery")
            speedControl.needsDisplay = true
            if let a = actOpt, mode == "custom", abs(a - rpm) > 150 {
                speedLabel.stringValue = "\(T("rpm"))　\(Int(a)) → \(Int(rpm)) RPM"
            } else {
                speedLabel.stringValue = "\(T("rpm"))　" + (actOpt.map { "\(Int($0)) RPM" } ?? T("noData"))
            }
        }
    }

    static func showPowerInBar() -> Bool {
        UserDefaults.standard.object(forKey: "showPowerInBar") == nil
            ? true : UserDefaults.standard.bool(forKey: "showPowerInBar")
    }

    func setBarText(temp: Double, power: Double, stale: Bool) {
        let key: String
        if stale {
            key = "stale"
        } else if AppDelegate.showPowerInBar() && power > 0 {
            key = "\(Int(temp.rounded()))|\(Int(power.rounded()))"
        } else {
            key = "\(Int(temp.rounded()))"
        }
        guard key != lastTitle else { return }
        lastTitle = key
        guard let btn = item.button else { return }
        if stale {
            btn.attributedTitle = NSAttributedString()
            btn.title = "–°"
            return
        }
        if AppDelegate.showPowerInBar() && power > 0 {
            // 主次字号：温度 11pt 半粗为主，功耗 8pt 为辅
            let pTop = NSMutableParagraphStyle()
            pTop.maximumLineHeight = 12; pTop.minimumLineHeight = 12; pTop.alignment = .center
            let pBot = NSMutableParagraphStyle()
            pBot.maximumLineHeight = 9; pBot.minimumLineHeight = 9; pBot.alignment = .center
            let attr = NSMutableAttributedString()
            attr.append(NSAttributedString(
                string: "\(Int(temp.rounded()))°\n",
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                             .paragraphStyle: pTop, .baselineOffset: -3]))
            attr.append(NSAttributedString(
                string: "\(Int(power.rounded()))W",
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium),
                             .paragraphStyle: pBot, .baselineOffset: -3]))
            btn.title = ""
            btn.attributedTitle = attr
        } else {
            btn.attributedTitle = NSAttributedString()
            btn.title = "\(Int(temp.rounded()))°"
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
