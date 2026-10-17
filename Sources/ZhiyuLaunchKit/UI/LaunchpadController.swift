import AppKit

/// Borderless, non-activating full-screen panel covering the current display.
///
/// Design choices:
/// - `.nonactivatingPanel` keeps the previously active app active, exactly like
///   Spotlight; the panel still becomes key so it can receive keyboard input.
/// - `canJoinAllSpaces` + `fullScreenAuxiliary` show it on the *current* Space
///   (including over full-screen apps) without creating its own full-screen Space.
/// - Level `.popUpMenu` puts it above the menu bar and normal windows.
final class LaunchpadPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the panel: positioning on the right screen, presentation animation,
/// screen-change handling and idle resource release.
///
/// Memory strategy: the panel is kept alive after closing so reopening is
/// instant. If it stays closed for a while (`idleReleaseDelay`) the whole content
/// view controller is torn down — the window backing store and layer tree are the
/// biggest memory consumers, and rebuilding them later takes only tens of
/// milliseconds because the icon cache lives in `IconStore`, not in the views.
@MainActor
final class LaunchpadController {
    private let panel: LaunchpadPanel
    private let catalog: AppCatalog
    private let layoutState: LayoutState
    private let iconStore: IconStore
    private let recentAppsStore: RecentAppsStore
    private let hiddenAppsStore: HiddenAppsStore

    private var content: LaunchpadViewController?
    private(set) var isVisible = false
    private var idleReleaseWorkItem: DispatchWorkItem?
    private nonisolated(unsafe) var screenObserver: NSObjectProtocol?

    /// Seconds after closing before the content is released. Overridable for QA.
    static let idleReleaseDelay: TimeInterval = {
        if let raw = ProcessInfo.processInfo.environment["ZHIYU_IDLE_RELEASE_SECONDS"],
           let value = TimeInterval(raw) {
            return value
        }
        return 30
    }()

    init(
        catalog: AppCatalog,
        layoutState: LayoutState,
        iconStore: IconStore,
        recentAppsStore: RecentAppsStore,
        hiddenAppsStore: HiddenAppsStore
    ) {
        self.catalog = catalog
        self.layoutState = layoutState
        self.iconStore = iconStore
        self.recentAppsStore = recentAppsStore
        self.hiddenAppsStore = hiddenAppsStore

        panel = LaunchpadPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = false
        panel.ignoresMouseEvents = false

        content = makeContent()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screenParametersChanged()
            }
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    // MARK: - Presentation

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard !isVisible else { return }
        cancelIdleRelease()
        let rebuilt = content == nil
        let controller = content ?? makeContent()

        let screen = Self.targetScreen()
        panel.setFrame(screen.frame, display: false)
        controller.prepareForPresentation(screen: screen)

        isVisible = true
        // The window itself appears instantly; the fade/scale happens on the
        // content layer. Animating window alpha proved unreliable for
        // non-activating panels and delays the panel's first frame.
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        AppLog.debug("show: frame=\(panel.frame) isVisible=\(panel.isVisible) key=\(panel.isKeyWindow) rebuilt=\(rebuilt)")

        controller.animateContentIn()
        controller.focusSearchField()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            AppLog.debug("show+0.5s: occlusion=\(self.panel.occlusionState.contains(.visible)) onActiveSpace=\(self.panel.isOnActiveSpace)")
        }
    }

    func hide() {
        guard isVisible else { return }
        AppLog.debug("hide requested: \(Thread.callStackSymbols.dropFirst().prefix(12).joined(separator: " | "))")
        isVisible = false
        completeHide()
    }

    private func completeHide() {
        content?.prepareForDismissal()
        content?.animateContentOut { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isVisible else { return }
                self.panel.orderOut(nil)
                self.content?.didDismiss()
                AppLog.debug("hide: ordered out")
                self.scheduleIdleRelease()
            }
        }
    }

    /// Called when the catalog changed (apps installed or removed).
    func refreshContent() {
        content?.contentChanged()
    }

    /// Called when another application became active (recently-used tracking).
    func refreshRecentApps() {
        content?.refreshRecentApps()
    }

    // MARK: - QA probes (built-in smoke test)

    var probeViewController: LaunchpadViewController? { content }
    var probeLayoutState: LayoutState { layoutState }

    /// QA only: keeps background clicks from closing the panel (stray mouse-ups
    /// from real input devices would end automated runs). Survives content rebuilds.
    var probeIgnoresBackgroundClose = false {
        didSet { content?.probeIgnoresBackgroundClose = probeIgnoresBackgroundClose }
    }

    // MARK: - Idle resource release

    private func scheduleIdleRelease() {
        idleReleaseWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.releaseIdleResources()
            }
        }
        idleReleaseWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleReleaseDelay, execute: item)
    }

    private func cancelIdleRelease() {
        idleReleaseWorkItem?.cancel()
        idleReleaseWorkItem = nil
    }

    private func releaseIdleResources() {
        guard !isVisible, content != nil else { return }
        AppLog.debug("releasing idle panel content")
        panel.contentViewController = nil
        content = nil
        // The icon cache is cheap to rebuild (background renders of the first
        // visible page, tens of milliseconds) but a few megabytes to keep alive.
        iconStore.clear()
    }

    // MARK: - Content lifecycle

    private func makeContent() -> LaunchpadViewController {
        let controller = LaunchpadViewController(
            catalog: catalog,
            layoutState: layoutState,
            iconStore: iconStore,
            recentAppsStore: recentAppsStore,
            hiddenAppsStore: hiddenAppsStore
        )
        controller.onRequestClose = { [weak self] in self?.hide() }
        controller.onAppLaunched = { [weak self] in self?.hide() }
        controller.probeIgnoresBackgroundClose = probeIgnoresBackgroundClose
        panel.contentViewController = controller
        content = controller
        return controller
    }

    // MARK: - Screen targeting

    private func screenParametersChanged() {
        guard isVisible, let content else { return }
        let screen = Self.targetScreen()
        panel.setFrame(screen.frame, display: true)
        content.prepareForPresentation(screen: screen)
        content.focusSearchField()
    }

    static func targetScreen() -> NSScreen {
        let mouseLocation = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
            return screen
        }
        if let main = NSScreen.main {
            return main
        }
        precondition(!NSScreen.screens.isEmpty, "A GUI session always has at least one screen")
        return NSScreen.screens[0]
    }
}
