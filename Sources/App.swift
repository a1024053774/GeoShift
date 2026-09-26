import AppKit
import ServiceManagement

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
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var timer: DispatchSourceTimer?
    private var shown: DayAppearance?
    private var lastError: String?
    private var activity: NSObjectProtocol?
    private var observers: [NSObjectProtocol] = []
    private var zoneMenuCache: (minute: Int, groups: [ZoneGroup])?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if terminateIfDuplicate() {
            return
        }

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

        DispatchQueue.main.async { [weak self] in
            self?.enforceAppearance(force: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.cancel()
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
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
    }

    private func updateBar(now: Date) {
        let zone = ZonePreference.actualTimeZone()
        let coordinate = ZoneLocation.resolved(for: zone, at: now)
        let appearance = SolarDay.appearance(at: now, timeZone: zone, coordinate: coordinate)
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
        let desired = SolarDay.appearance(at: now, timeZone: zone, coordinate: ZoneLocation.resolved(for: zone, at: now))
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
            return "切换外观超时。请在「系统设置 → 隐私与安全性 → 自动化」允许「东八外观」控制「系统事件」。"
        }
        guard process.terminationStatus == 0 else {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if message.localizedCaseInsensitiveContains("not authorized")
                || message.contains("-1743")
                || message.contains("1002") {
                return "请到「系统设置 → 隐私与安全性 → 自动化」，允许「东八外观」控制「系统事件」。"
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
        let appearance = SolarDay.appearance(at: now, timeZone: actual, coordinate: coordinate)

        addDisabled(menu, title: "实际  \(ChinaClock.zoneLine(at: now, timeZone: actual))")
        addDisabled(menu, title: "伪装  \(ChinaClock.zoneLine(at: now, timeZone: disguise))")
        addDisabled(menu, title: ChinaClock.lagSummary(actual: actual, disguise: disguise, at: now))
        addDisabled(menu, title: "\(appearance.label) · \(SolarDay.nextChangeDescription(after: now, timeZone: actual, coordinate: coordinate))")
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
        guard identifier != ZonePreference.actualTimeZone().identifier else { return }
        let title = ZoneCatalog.title(for: identifier, at: Date())
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "切换实际时区"
        alert.informativeText = "实际位置改成 \(title) 吗？菜单栏时间和深浅色会按这个时区的日出日落计算。Mac 的系统时区不变。"
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
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
            lastError = nil
        } catch {
            lastError = "登录启动未生效：\(error.localizedDescription)"
        }
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
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
