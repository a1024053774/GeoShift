import AppKit
import ServiceManagement
import SwiftUI

enum AppearanceControl: String, CaseIterable, Identifiable {
    case automatic, light, dark
    var id: String { rawValue }
    var label: String {
        switch self { case .automatic: "自动（日出日落）"; case .light: "浅色"; case .dark: "深色" }
    }
    var manualAppearance: DayAppearance? {
        switch self { case .automatic: nil; case .light: .light; case .dark: .dark }
    }
    static func load() -> Self {
        UserDefaults.standard.string(forKey: "appearanceControlMode").flatMap(Self.init(rawValue:)) ?? .automatic
    }
}

enum MainPanel: String, Hashable { case location, preferences }

private enum GlobalPreference {
    static func string(_ key: String) -> String? {
        CFPreferencesCopyAppValue(key as CFString, kCFPreferencesAnyApplication) as? String
    }

    static func bool(_ key: String) -> Bool {
        let value = CFPreferencesCopyAppValue(key as CFString, kCFPreferencesAnyApplication)
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return false
    }

    static func set(_ key: String, _ value: CFPropertyList?) {
        let name = key as CFString
        for host in [kCFPreferencesAnyHost, kCFPreferencesCurrentHost] {
            CFPreferencesSetValue(name, value, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, host)
            CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, host)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, ObservableObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    let locationModel = LocationModel()
    @Published var activePanel = MainPanel.location
    @Published private(set) var settingsRevision = 0
    private var mainWindow: NSWindow?
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var timer: DispatchSourceTimer?
    private var shown: DayAppearance?
    @Published private var lastError: String?
    private var activity: NSObjectProtocol?
    private var observers: [NSObjectProtocol] = []
    private var zoneMenuCache: (minute: Int, groups: [ZoneGroup])?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if terminateIfDuplicate() {
            return
        }
        installWindowMenus()

        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "按实际时区更新菜单栏时钟和深浅色"
        )

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            button.imagePosition = .imageLeading
        }
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.sync()
            }
        }
        self.timer = timer
        updateBar(now: Date())
        arm(now: Date())
        timer.resume()
        observeSystemChanges()
        locationModel.startReading()
        if CommandLine.arguments.contains("--show-window") { showMainWindow(panel: .location) }

        DispatchQueue.main.async { [weak self] in
            self?.enforceAppearance(force: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.cancel()
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
        release_location_authorization()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        locationModel.busy ? .terminateCancel : .terminateNow
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow(panel: activePanel)
        return true
    }

    var actualZoneIdentifier: String { ZonePreference.actualTimeZone().identifier }
    var systemZoneIdentifier: String { TimeZone.current.identifier }
    var actualClockText: String { ChinaClock.zoneLine(at: Date(), timeZone: ZonePreference.actualTimeZone()) }
    var systemClockText: String { ChinaClock.zoneLine(at: Date(), timeZone: TimeZone.current) }
    var timeDifferenceText: String { ChinaClock.lagSummary(actual: ZonePreference.actualTimeZone(), disguise: TimeZone.current, at: Date()) }
    var appearanceControl: AppearanceControl { AppearanceControl.load() }
    var appearanceDescription: String {
        if appearanceControl != .automatic { return "手动\(appearanceControl.label)" }
        let now = Date(), zone = ZonePreference.actualTimeZone()
        return SolarDay.nextChangeDescription(after: now, timeZone: zone, coordinate: ZoneLocation.resolved(for: zone, at: now))
    }
    var loginEnabled: Bool { SMAppService.mainApp.status == .enabled }
    var settingsError: String? { lastError }
    var availableZones: [ZoneGroup] { cachedZoneGroups(at: Date()) }

    func showMainWindow(panel: MainPanel) {
        activePanel = panel
        NSApp.setActivationPolicy(.regular)
        if mainWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "GeoShift"
            window.contentView = NSHostingView(rootView: DongbaWindow(controller: self, location: locationModel))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setFrameAutosaveName("DongbaMainWindow")
            window.center()
            mainWindow = window
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === mainWindow {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func installWindowMenus() {
        let bar = NSMenu()
        let appMenu = NSMenu(title: "GeoShift")
        let about = NSMenuItem(title: "关于GeoShift", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        about.target = NSApp; appMenu.addItem(about)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "退出GeoShift", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp; appMenu.addItem(quit)
        let appRoot = NSMenuItem(); appRoot.submenu = appMenu; bar.addItem(appRoot)
        let edit = NSMenu(title: "编辑")
        for (title, selector, key) in [("撤销", NSSelectorFromString("undo:"), "z"), ("剪切", #selector(NSText.cut(_:)), "x"),
            ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(NSMenuItem(title: title, action: selector, keyEquivalent: key))
        }
        let editRoot = NSMenuItem(title: "编辑", action: nil, keyEquivalent: ""); editRoot.submenu = edit; bar.addItem(editRoot)
        let windows = NSMenu(title: "窗口")
        windows.addItem(NSMenuItem(title: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windows.addItem(NSMenuItem(title: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        let windowRoot = NSMenuItem(title: "窗口", action: nil, keyEquivalent: ""); windowRoot.submenu = windows; bar.addItem(windowRoot)
        NSApp.mainMenu = bar
        NSApp.windowsMenu = windows
    }

    func selectAppearanceControl(_ control: AppearanceControl) {
        UserDefaults.standard.set(control.rawValue, forKey: "appearanceControlMode")
        applied = nil; suppressed = nil; shown = nil
        sync()
    }

    func setLoginEnabled(_ enabled: Bool) {
        guard enabled != loginEnabled else { return }
        let service = SMAppService.mainApp
        do {
            if enabled { try service.register() } else { try service.unregister() }
            lastError = nil
        } catch {
            lastError = "登录启动未生效：\(error.localizedDescription)"
        }
        settingsRevision += 1
    }

    private func effectiveAppearance(at now: Date, zone: TimeZone) -> DayAppearance {
        AppearanceControl.load().manualAppearance ?? SolarDay.appearance(at: now, timeZone: zone, coordinate: ZoneLocation.resolved(for: zone, at: now))
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let now = Date()
        updateBar(now: now)
        menu.removeAllItems()
        populate(menu)
    }

    private func terminateIfDuplicate() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let pid = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != pid }
        guard !others.isEmpty else { return false }
        NSApp.terminate(nil)
        return true
    }

    private func observeSystemChanges() {
        observers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.sync()
                }
            }
        )

        let names = [
            Notification.Name("NSSystemClockDidChangeNotification"),
            Notification.Name("NSSystemTimeZoneDidChangeNotification"),
        ]
        for name in names {
            for center in [NotificationCenter.default, DistributedNotificationCenter.default()] {
                observers.append(
                    center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated {
                            self?.sync()
                        }
                    }
                )
            }
        }
    }

    private var applied: DayAppearance?
    private var suppressed: DayAppearance?

    private func sync() {
        let now = Date()
        updateBar(now: now)
        enforceAppearance(force: false)
        arm(now: now)
        settingsRevision += 1
    }

    private func updateBar(now: Date) {
        let zone = ZonePreference.actualTimeZone()
        let appearance = effectiveAppearance(at: now, zone: zone)
        guard let button = statusItem?.button else { return }
        let title = ChinaClock.zoneLine(at: now, timeZone: zone)
        if button.title != title {
            button.title = title
        }
        button.toolTip = "\(ZoneCatalog.title(for: zone.identifier, at: now)) \(title) · \(appearance.label)"
        button.setAccessibilityLabel(button.toolTip)
        if shown != appearance {
            button.image = symbol(for: appearance)
            shown = appearance
        }
    }

    private func symbol(for appearance: DayAppearance) -> NSImage {
        let name = appearance == .light ? "sun.max" : "moon"
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: appearance.label) else {
            return NSImage()
        }
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let image = base.withSymbolConfiguration(config) ?? base
        image.isTemplate = true
        return image
    }

    private func arm(now: Date) {
        guard let timer else { return }
        let delay = max(ChinaClock.nextMinute(after: now, timeZone: ZonePreference.actualTimeZone()).timeIntervalSinceNow, 0.3)
        timer.schedule(wallDeadline: .now() + delay, leeway: .seconds(1))
    }

    private func enforceAppearance(force: Bool) {
        let now = Date()
        let zone = ZonePreference.actualTimeZone()
        let desired = effectiveAppearance(at: now, zone: zone)
        disableSystemAutoAppearance()
        let matches = systemIsDark() == (desired == .dark)
        if !force && desired == applied && matches { return }
        if !force && desired == suppressed { return }
        if let error = setSystemAppearance(desired) {
            lastError = error
            suppressed = desired
        } else {
            applied = desired
            suppressed = nil
            lastError = nil
        }
        updateBar(now: now)
    }

    private func disableSystemAutoAppearance() {
        let key = "AppleInterfaceStyleSwitchesAutomatically"
        guard GlobalPreference.bool(key) else { return }
        GlobalPreference.set(key, kCFBooleanFalse)
    }

    private func systemIsDark() -> Bool {
        GlobalPreference.string("AppleInterfaceStyle") == "Dark"
    }

    private func setSystemAppearance(_ appearance: DayAppearance) -> String? {
        let source = """
        tell application "System Events"
            tell appearance preferences
                set dark mode to \(appearance == .dark ? "true" : "false")
            end tell
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return "无法切换外观：\(error.localizedDescription)"
        }

        let deadline = Date().addingTimeInterval(120)
        while process.isRunning && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        }
        if process.isRunning {
            process.terminate()
            return "切换外观超时。请在「系统设置 → 隐私与安全性 → 自动化」允许「GeoShift」控制「系统事件」。"
        }
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if message.localizedCaseInsensitiveContains("not authorized")
                || message.contains("-1743")
                || message.contains("1002") {
                return "请到「系统设置 → 隐私与安全性 → 自动化」，允许「GeoShift」控制「系统事件」。"
            }
            return message.isEmpty ? "切换系统外观失败" : message
        }
        return nil
    }

    private func populate(_ menu: NSMenu) {
        let now = Date()
        let actual = ZonePreference.actualTimeZone()
        let disguise = TimeZone.current
        let coordinate = ZoneLocation.resolved(for: actual, at: now)
        let appearance = effectiveAppearance(at: now, zone: actual)

        addDisabled(menu, title: "实际  \(ChinaClock.zoneLine(at: now, timeZone: actual))")
        addDisabled(menu, title: "伪装  \(ChinaClock.zoneLine(at: now, timeZone: disguise))")
        addDisabled(menu, title: ChinaClock.lagSummary(actual: actual, disguise: disguise, at: now))
        let next = appearanceControl == .automatic ? SolarDay.nextChangeDescription(after: now, timeZone: actual, coordinate: coordinate) : "手动控制"
        addDisabled(menu, title: "\(appearance.label) · \(next)")
        menu.addItem(.separator())
        let open = NSMenuItem(title: "打开主窗口…", action: #selector(openWindow(_:)), keyEquivalent: "o")
        open.target = self; open.keyEquivalentModifierMask = .command
        menu.addItem(open)
        let locationMenu = NSMenu()
        if let point = locationModel.currentLocation {
            addDisabled(locationMenu, title: String(format: "系统坐标 %.6f, %.6f", point.coordinate.latitude, point.coordinate.longitude))
        }
        addDisabled(locationMenu, title: locationModel.message)
        let coordinates = NSMenuItem(title: "输入坐标并设置…", action: #selector(inputCoordinates(_:)), keyEquivalent: "")
        coordinates.target = self; coordinates.isEnabled = !locationModel.busy
        locationMenu.addItem(coordinates)
        let apply = NSMenuItem(title: "应用所选位置", action: #selector(applyLocation(_:)), keyEquivalent: "")
        apply.target = self; apply.isEnabled = !locationModel.busy && locationModel.selectedCoordinate != nil
        locationMenu.addItem(apply)
        let restore = NSMenuItem(title: "恢复真实定位", action: #selector(restoreLocation(_:)), keyEquivalent: "")
        restore.target = self; restore.isEnabled = !locationModel.busy
        locationMenu.addItem(restore)
        let map = NSMenuItem(title: "在窗口中选点…", action: #selector(openLocation(_:)), keyEquivalent: "")
        map.target = self; locationMenu.addItem(map)
        let locationRoot = NSMenuItem(title: "系统定位", action: nil, keyEquivalent: "")
        locationRoot.submenu = locationMenu; menu.addItem(locationRoot)
        let appearanceMenu = NSMenu()
        for control in AppearanceControl.allCases {
            let item = NSMenuItem(title: control.label, action: #selector(chooseAppearance(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = control.rawValue
            item.state = control == appearanceControl ? .on : .off
            appearanceMenu.addItem(item)
        }
        let appearanceRoot = NSMenuItem(title: "外观  \(appearanceControl.label)", action: nil, keyEquivalent: "")
        appearanceRoot.submenu = appearanceMenu; menu.addItem(appearanceRoot)
        menu.addItem(.separator())
        addTimeZoneMenu(
            menu,
            title: "实际时区  \(ZoneCatalog.title(for: actual.identifier, at: now))",
            selected: actual.identifier,
            at: now,
            action: #selector(chooseActualTimeZone(_:))
        )
        addTimeZoneMenu(
            menu,
            title: "伪装时区  \(ZoneCatalog.title(for: disguise.identifier, at: now))",
            selected: disguise.identifier,
            at: now,
            action: #selector(chooseTimeZone(_:))
        )
        menu.addItem(.separator())

        if let lastError {
            addDisabled(menu, title: lastError)
        }

        let login = NSMenuItem(title: "登录时启动", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = .command
        quit.target = self
        menu.addItem(quit)
    }

    private func addDisabled(_ menu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addTimeZoneMenu(
        _ menu: NSMenu,
        title: String,
        selected: String,
        at date: Date,
        action: Selector
    ) {
        let submenu = NSMenu()
        for group in cachedZoneGroups(at: date) {
            let groupMenu = NSMenu()
            for zone in group.zones {
                let item = NSMenuItem(title: zone.title, action: action, keyEquivalent: "")
                item.representedObject = zone.identifier
                item.target = self
                item.state = zone.identifier == selected ? .on : .off
                groupMenu.addItem(item)
            }
            let parent = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
            parent.submenu = groupMenu
            submenu.addItem(parent)
        }
        let root = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        root.submenu = submenu
        menu.addItem(root)
    }

    private func cachedZoneGroups(at date: Date) -> [ZoneGroup] {
        let minute = Int(date.timeIntervalSince1970 / 60)
        if let zoneMenuCache, zoneMenuCache.minute == minute {
            return zoneMenuCache.groups
        }
        let groups = ZoneCatalog.groups(at: date)
        zoneMenuCache = (minute, groups)
        return groups
    }

    @objc private func chooseTimeZone(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        changeSystemZone(identifier)
    }

    func changeSystemZone(_ identifier: String) {
        guard ZoneCatalog.isValidIdentifier(identifier) else { return }
        guard identifier != TimeZone.current.identifier else { return }
        let title = ZoneCatalog.title(for: identifier, at: Date())
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "切换伪装时区"
        alert.informativeText = "要把 Mac 的系统时区改为 \(title) 吗？系统时钟会改成这个时区。菜单栏时间和深浅色仍按实际时区计算。确认后需要输入管理员密码。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "切换")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        if let error = setSystemTimeZone(identifier) {
            lastError = error
        } else {
            lastError = nil
            NSTimeZone.resetSystemTimeZone()
            zoneMenuCache = nil
            sync()
        }
    }

    private func setSystemTimeZone(_ identifier: String) -> String? {
        guard let source = ZoneCatalog.administratorScript(identifier: identifier) else {
            return "时区名称无效"
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return "无法切换时区：\(error.localizedDescription)"
        }

        let deadline = Date().addingTimeInterval(180)
        while process.isRunning && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        }
        if process.isRunning {
            process.terminate()
            return "切换时区超时。请再选一次，并在系统密码框里确认。"
        }
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if message.contains("-128") || message.localizedCaseInsensitiveContains("User canceled") {
                return nil
            }
            return message.isEmpty ? "切换系统时区失败" : message
        }
        return nil
    }

    @objc private func chooseActualTimeZone(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        changeActualZone(identifier)
    }

    func changeActualZone(_ identifier: String) {
        guard ZoneCatalog.isValidIdentifier(identifier) else { return }
        guard identifier != ZonePreference.actualTimeZone().identifier else { return }
        let title = ZoneCatalog.title(for: identifier, at: Date())
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "切换实际时区"
        alert.informativeText = "实际时区改成 \(title) 吗？菜单栏时间和自动深浅色会按这个时区的日出日落计算。Mac 的系统时区和定位不变。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "切换")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        ZonePreference.saveActual(identifier)
        applied = nil
        suppressed = nil
        shown = nil
        sync()
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        setLoginEnabled(!loginEnabled)
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    @objc private func openWindow(_ sender: NSMenuItem) { showMainWindow(panel: activePanel) }
    @objc private func openLocation(_ sender: NSMenuItem) { showMainWindow(panel: .location) }
    @objc private func applyLocation(_ sender: NSMenuItem) { locationModel.applySelection() }
    @objc private func restoreLocation(_ sender: NSMenuItem) { locationModel.restoreOriginal() }
    @objc private func chooseAppearance(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let control = AppearanceControl(rawValue: raw) else { return }
        selectAppearanceControl(control)
    }
    @objc private func inputCoordinates(_ sender: NSMenuItem) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "设置系统定位"
        alert.informativeText = "输入纬度（−90～90）和经度（−180～180）。"
        let latitude = NSTextField(string: locationModel.latitude)
        let longitude = NSTextField(string: locationModel.longitude)
        latitude.placeholderString = "纬度"; longitude.placeholderString = "经度"
        let stack = NSStackView(views: [latitude, longitude])
        stack.orientation = .vertical; stack.spacing = 10
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 64)
        alert.accessoryView = stack
        alert.addButton(withTitle: "设置"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        locationModel.latitude = latitude.stringValue
        locationModel.longitude = longitude.stringValue
        locationModel.selectionDidChange()
        guard locationModel.selectedCoordinate != nil else {
            showMainWindow(panel: .location)
            return
        }
        locationModel.applySelection()
    }
}

@main
enum DongbaMain {
    static func main() {
        if CommandLine.arguments.contains("--status") {
            print(ChinaClock.report(at: Date(), schedule: DaySchedule.load()))
            return
        }

        let delegate = AppDelegate()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }
}
