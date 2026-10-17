import AppKit

/// Lightweight debug logging, enabled with `ZHIYU_DEBUG=1`.
enum AppLog {
    static let isEnabled = ProcessInfo.processInfo.environment["ZHIYU_DEBUG"] == "1"

    static func debug(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        NSLog("[ZhiyuLaunch] \(message())")
    }
}

/// Application entry point and lifecycle wiring. Kept small on purpose: it only
/// assembles the catalog, layout, panel and menu bar pieces and connects them.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let catalog = AppCatalog()
    // UITEST runs use an isolated layout file so the smoke test never touches
    // the user's real layout (it creates and restores folders while running).
    private lazy var layoutState: LayoutState = {
        if ProcessInfo.processInfo.environment["ZHIYU_UITEST"] == "1" {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("zhiyu-uitest-layout-\(getpid()).json")
            NSLog("[ZhiyuLaunch] UITEST: isolated layout store at \(url.path)")
            return LayoutState(store: LayoutStore(fileURL: url))
        }
        return LayoutState()
    }()
    private let iconStore = IconStore()
    private let hotKeyManager = HotKeyManager()
    private let preferences = Preferences.shared
    // UITEST runs use an isolated defaults domain so tests never touch real data.
    private lazy var uiTestDefaults: UserDefaults? = {
        guard ProcessInfo.processInfo.environment["ZHIYU_UITEST"] == "1" else { return nil }
        return UserDefaults(suiteName: "com.zhiyu.launch.uitest") ?? .standard
    }()
    private lazy var recentAppsStore = RecentAppsStore(defaults: uiTestDefaults ?? .standard)
    private lazy var hiddenAppsStore = HiddenAppsStore(defaults: uiTestDefaults ?? .standard)
    private var workspaceObservers: [NSObjectProtocol] = []

    private var launchpad: LaunchpadController?
    private var statusBar: StatusBarController?
    private var settingsController: SettingsWindowController?
    private var uiTestRunner: UITestRunner?
    private var uiTestStarted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(preferences.showMenuBarIcon ? .accessory : .regular)

        launchpad = LaunchpadController(
            catalog: catalog,
            layoutState: layoutState,
            iconStore: iconStore,
            recentAppsStore: recentAppsStore,
            hiddenAppsStore: hiddenAppsStore
        )

        // Track application activations (system-wide) for the recently-used strip.
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let activationToken = workspaceCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // Extract Sendable values before hopping onto the main actor; the
            // notification itself is not Sendable.
            let runningApp = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = runningApp?.bundleIdentifier
            let isRegular = runningApp?.activationPolicy == .regular
            MainActor.assumeIsolated {
                guard let self, let bundleID, isRegular else { return }
                self.recentAppsStore.record(bundleID)
                self.launchpad?.refreshRecentApps()
            }
        }
        workspaceObservers.append(activationToken)

        catalog.onChange = { [weak self] apps in
            guard let self else { return }
            // Keep the user's ordering; append new apps, drop removed ones.
            // Skip reconciliation until a full directory scan has run: Spotlight
            // results alone may arrive first and would drop most of the layout.
            if self.catalog.hasCompletedDirectoryScan {
                self.layoutState.mutate { $0.reconcile(with: apps) }
            }
            self.launchpad?.refreshContent()
            self.maybeStartUITest()
        }

        hotKeyManager.onTrigger = { [weak self] in
            self?.launchpad?.toggle()
        }
        if !hotKeyManager.register(preferences.hotKey) {
            NSLog("[ZhiyuLaunch] global hot key \(preferences.hotKey.displayString) could not be registered")
        }

        let statusBar = StatusBarController()
        statusBar.onOpenLaunchpad = { [weak self] in self?.launchpad?.show() }
        statusBar.onOpenSettings = { [weak self] in self?.showSettings() }
        statusBar.onQuit = { NSApp.terminate(nil) }
        statusBar.onMenuBarVisibilityChanged = { [weak self] show in self?.applyMenuBarPreference(show) }
        statusBar.setVisible(preferences.showMenuBarIcon)
        self.statusBar = statusBar

        catalog.start()

        // Open once on the very first launch so users immediately see the result.
        let autoShow = ProcessInfo.processInfo.environment["ZHIYU_AUTOSHOW"] == "1"
        if autoShow || !preferences.hasLaunchedBefore {
            preferences.hasLaunchedBefore = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.launchpad?.show()
            }
        }

        // Development helpers used by the QA script:
        // - ZHIYU_SELFTEST=1: measure memory with the panel open and closed, then exit.
        // - ZHIYU_SNAPSHOT=1: self-render the panel to /tmp/zhiyu-selftest.png, then exit.
        // - ZHIYU_UITEST=1: run the built-in interaction smoke test, then exit.
        //   (Started from the catalog callback so the grid is fully populated first.)
        if ProcessInfo.processInfo.environment["ZHIYU_SELFTEST"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.runSelfTest()
            }
        } else if ProcessInfo.processInfo.environment["ZHIYU_SNAPSHOT"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.runSnapshot()
            }
        }
    }

    private func maybeStartUITest() {
        guard !uiTestStarted,
              ProcessInfo.processInfo.environment["ZHIYU_UITEST"] == "1",
              catalog.hasCompletedDirectoryScan,
              catalog.apps.count > 50 else { return }
        uiTestStarted = true

        // Seed the recently-used strip with installed apps so the test can
        // exercise its visibility rules (the isolated defaults start empty).
        let seed = catalog.apps.prefix(2)
        for app in seed.reversed() {
            recentAppsStore.record(app.bundleID)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, let launchpad = self.launchpad else { exit(1) }
            let runner = UITestRunner(controller: launchpad)
            self.uiTestRunner = runner
            runner.run()
        }
    }

    private func runSelfTest() {
        // Real mouse-ups from the user's input devices would close the panel
        // mid-measurement; the close path is covered by its own QA step in UITEST.
        launchpad?.probeIgnoresBackgroundClose = true

        let panelVisible = launchpad?.isVisible == true
        logMemory(panelVisible ? "panel open" : "idle, panel never shown")

        guard panelVisible else {
            exit(0)
        }
        launchpad?.hide()
        let wait = LaunchpadController.idleReleaseDelay + 2.0
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            self.logMemory("panel closed + idle released")

            // Rebuild path: the content view controller was torn down; measure how
            // long a fresh open takes and where memory lands.
            let start = ProcessInfo.processInfo.systemUptime
            self.launchpad?.show()
            let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
            NSLog("[ZhiyuLaunch] selftest reopen (rebuilt content) took \(String(format: "%.1f", elapsed))ms")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.logMemory("panel reopened after release")
                exit(0)
            }
        }
    }

    private func runSnapshot() {
        AppLog.debug("snapshot: NSApp windows")
        for window in NSApp.windows {
            NSLog("[ZhiyuLaunch] snapshot window: class=\(type(of: window)) title='\(window.title)' frame=\(window.frame) alpha=\(window.alphaValue) visible=\(window.isVisible) level=\(window.level.rawValue) occlusionVisible=\(window.occlusionState.contains(.visible))")
        }
        if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] {
            let pid = Int(getpid())
            var foundAny = false
            for info in list where (info[kCGWindowOwnerPID as String] as? Int) == pid {
                foundAny = true
                NSLog("[ZhiyuLaunch] snapshot onscreen cgwindow: \(info)")
            }
            if !foundAny {
                NSLog("[ZhiyuLaunch] snapshot: no onscreen windows for pid \(pid)")
            }
        }

        // Self-render the panel into a PNG (no screen-recording permission needed).
        if let contentView = NSApp.windows.first(where: { $0 is LaunchpadPanel })?.contentView,
           let rep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) {
            contentView.cacheDisplay(in: contentView.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                let url = URL(fileURLWithPath: "/tmp/zhiyu-selftest.png")
                try? data.write(to: url)
                NSLog("[ZhiyuLaunch] snapshot saved: \(url.path)")
            }
        }
        exit(0)
    }

    private func logMemory(_ label: String) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        if result == KERN_SUCCESS {
            NSLog("[ZhiyuLaunch] selftest memory [\(label)]: phys_footprint=\(info.phys_footprint / 1024 / 1024)MB resident=\(info.resident_size / 1024 / 1024)MB")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        layoutState.saveNow()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - Private

    private func showSettings() {
        if settingsController == nil {
            let controller = SettingsWindowController(
                hotKeyManager: hotKeyManager,
                hiddenAppsStore: hiddenAppsStore
            )
            controller.onMenuBarVisibilityChanged = { [weak self] show in
                self?.applyMenuBarPreference(show)
            }
            controller.onToggleRecentApps = { [weak self] _ in
                self?.launchpad?.refreshRecentApps()
            }
            controller.onUnhideAll = { [weak self] in
                guard let self else { return }
                self.hiddenAppsStore.unhideAll()
                self.launchpad?.refreshContent()
            }
            controller.onResetLayout = { [weak self] in
                guard let self else { return }
                self.layoutState.mutate { model in
                    model = LayoutModel()
                    _ = model.reconcile(with: self.catalog.apps)
                    return true
                }
                self.layoutState.saveNow()
                self.launchpad?.refreshContent()
            }
            settingsController = controller
        }
        settingsController?.show()
    }

    /// Without a menu bar icon the app would be unreachable; show a Dock icon instead.
    private func applyMenuBarPreference(_ show: Bool) {
        statusBar?.setVisible(show)
        NSApp.setActivationPolicy(show ? .accessory : .regular)
    }

    /// Bound to the main menu's Close item (⌘W). The menu's target is nil so the
    /// action travels the responder chain and lands here.
    @objc func closeLaunchpad(_ sender: Any?) {
        launchpad?.hide()
    }
}

/// Public entry point used by the thin executable target.
public enum ZhiyuLaunchApp {
    @MainActor
    public static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)

        // A minimal main menu. LSUIElement apps never show a menu bar, but the
        // menu still provides standard key equivalents (⌘Q, ⌘W) and text editing
        // shortcuts (⌘X/⌘C/⌘V/⌘A) for the search field.
        app.mainMenu = Self.makeMainMenu()

        app.run()
    }

    @MainActor
    private static func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 Zhiyu Launch", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 Zhiyu Launch", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 Zhiyu Launch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "关闭启动台", action: #selector(AppDelegate.closeLaunchpad(_:)), keyEquivalent: "w")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        return mainMenu
    }
}
