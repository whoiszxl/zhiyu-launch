import AppKit

/// The Launchpad screen itself: grid, search field, page indicator, selection,
/// drag & drop and the folder overlay. This class is the single coordinator for
/// everything that happens while the window is visible.
@MainActor
final class LaunchpadViewController: NSViewController {
    // MARK: - Dependencies

    private let catalog: AppCatalog
    private let layoutState: LayoutState
    private let iconStore: IconStore
    private let recentAppsStore: RecentAppsStore
    private let hiddenAppsStore: HiddenAppsStore

    // MARK: - Callbacks

    /// Called when the user asks to dismiss the launchpad (Esc, background click).
    var onRequestClose: (() -> Void)?
    /// Called right after an app was launched or activated.
    var onAppLaunched: (() -> Void)?

    // MARK: - Views

    private let backgroundEffect = PassthroughEffectView()
    private let scrim = PassthroughView()
    private let contentContainer = NSView()
    private let searchField = NSSearchField()
    private let collectionView = LaunchpadCollectionView()
    private let layout = LaunchpadLayout()
    private let indicator = PageIndicatorView()
    private let dropLine = DropLineView()
    private let folderOverlay = FolderOverlayView()
    private let emptyStateLabel = NSTextField(labelWithString: "")
    private let recentStrip = RecentAppsView()
    private var recentItems: [AppItem] = []

    // MARK: - State

    private var metrics = GridMetrics.compute(for: CGSize(width: 1440, height: 900))
    private var backingScale: CGFloat = 2
    private var displayCells: [LaunchpadCellModel] = []
    private var searchQuery = ""
    private var dragSourceIndex: Int?
    private var dropPlan: DropPlan?
    /// The selection the controller wants; re-applied after layout passes because
    /// `reloadData()` can clear it asynchronously.
    private var desiredSelectionIndex: Int?
    /// Continuous page position; animating it flips pages.
    private var pageOffset: CGFloat = 0
    private var pageAnimationTimer: Timer?
    private var pageAnimation: (from: CGFloat, to: CGFloat, start: TimeInterval, duration: TimeInterval)?
    private var wheelCooldownUntil: TimeInterval = 0
    // Live-follow trackpad gesture state.
    private var gestureActive = false
    private var gestureBaseOffset: CGFloat = 0
    private var gestureTravel: CGFloat = 0
    private var gestureSnapWorkItem: DispatchWorkItem?
    /// QA only: suppresses background-click-to-close while the smoke test runs.
    var probeIgnoresBackgroundClose = false
    private nonisolated(unsafe) var themeObserver: NSObjectProtocol?

    private var isSearching: Bool { !searchQuery.isEmpty }

    private var currentPage: Int { Int(pageOffset.rounded()) }
    private var pageCount: Int { max(1, layout.pageCount) }
    private var isPageAnimating: Bool { pageAnimation != nil }

    private var isDarkAppearance: Bool {
        view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

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
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let themeObserver {
            DistributedNotificationCenter.default().removeObserver(themeObserver)
        }
    }

    // MARK: - View lifecycle

    override func loadView() {
        let root = LaunchpadRootView()
        root.wantsLayer = true
        view = root
        root.onBackgroundClick = { [weak self] in
            self?.requestCloseFromBackground()
        }
        root.onKeyDown = { [weak self] event in
            self?.handleFallbackKeyDown(event) ?? false
        }

        backgroundEffect.material = .fullScreenUI
        backgroundEffect.blendingMode = .behindWindow
        backgroundEffect.state = .active
        view.addSubview(backgroundEffect)

        scrim.wantsLayer = true
        scrim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.08).cgColor
        view.addSubview(scrim)

        contentContainer.wantsLayer = true
        view.addSubview(contentContainer)

        configureCollectionView()
        configureSearchField()
        configureIndicator()
        configureFolderOverlay()

        dropLine.isHidden = true
        emptyStateLabel.font = .systemFont(ofSize: 16)
        emptyStateLabel.textColor = .secondaryLabelColor
        emptyStateLabel.alignment = .center
        emptyStateLabel.isSelectable = false
        emptyStateLabel.isHidden = true
        contentContainer.addSubview(collectionView)
        contentContainer.addSubview(searchField)
        contentContainer.addSubview(indicator)
        contentContainer.addSubview(dropLine)
        contentContainer.addSubview(folderOverlay)
        contentContainer.addSubview(emptyStateLabel)
        recentStrip.isHidden = true
        recentStrip.onLaunch = { [weak self] app in self?.launch(app) }
        recentStrip.onRemoveRecent = { [weak self] app in self?.removeFromRecents(app) }
        contentContainer.addSubview(recentStrip)

        themeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Folder thumbnails embed light/dark dependent colors; refresh them.
                self?.collectionView.reloadData()
            }
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let bounds = view.bounds
        backgroundEffect.frame = bounds
        scrim.frame = bounds
        contentContainer.frame = bounds
        collectionView.frame = contentContainer.bounds
        folderOverlay.frame = contentContainer.bounds

        let searchWidth = min(340, max(220, bounds.width * 0.26))
        searchField.frame = NSRect(
            x: ((bounds.width - searchWidth) / 2).rounded(),
            y: bounds.height - 68,
            width: searchWidth,
            height: 30
        )
        indicator.frame = NSRect(x: 0, y: 26, width: bounds.width, height: 22)
        emptyStateLabel.frame = NSRect(x: 0, y: bounds.midY - 12, width: bounds.width, height: 24)
        recentStrip.frame = NSRect(x: 0, y: bounds.height - 176, width: bounds.width, height: 72)

        if abs(layout.pageWidth - bounds.width) > 0.5, bounds.width > 0 {
            layout.pageWidth = bounds.width
            clampPageOffset()
        }
        layout.invalidateLayout()

        // `reloadData()` applies its effect during the following layout pass and can
        // clear the selection set just before it; restore the intended selection
        // once the pass has settled.
        if collectionView.selectionIndexPaths.isEmpty,
           let desired = desiredSelectionIndex,
           displayCells.indices.contains(desired) {
            collectionView.selectionIndexPaths = [IndexPath(item: desired, section: 0)]
        }
    }

    // MARK: - Setup helpers

    private func configureCollectionView() {
        layout.metrics = metrics
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.register(AppCell.self, forItemWithIdentifier: AppCell.reuseIdentifier)
        collectionView.registerForDraggedTypes([.zhiyuGridItem])
        collectionView.setDraggingSourceOperationMask(.move, forLocal: true)
        collectionView.onItemClick = { [weak self] indexPath in
            self?.activateCell(at: indexPath.item)
        }
        collectionView.onBackgroundClick = { [weak self] in
            self?.requestCloseFromBackground()
        }
        collectionView.onScroll = { [weak self] event in
            self?.handleScrollEvent(event)
        }
        collectionView.onContextMenu = { [weak self] index in
            self?.makeContextMenu(for: index)
        }
        collectionView.itemIndexAtPoint = { [weak self] point in
            guard let self else { return nil }
            let viewportHeight = self.collectionView.bounds.height
            guard viewportHeight > 0 else { return nil }
            for index in self.displayCells.indices
            where self.layout.frame(forItem: index, viewportHeight: viewportHeight).contains(point) {
                return index
            }
            return nil
        }
    }

    // MARK: - Paging

    /// Central page switch. `animated` runs a short ease-out interpolation of the
    /// layout's `pageOffset` on a 60 Hz timer.
    private func go(toPage page: Int, animated: Bool) {
        let target = min(max(0, page), pageCount - 1)
        stopPageAnimation()
        AppLog.debug("page.go target=\(target) current=\(pageOffset) animated=\(animated)")

        if !animated || abs(pageOffset - CGFloat(target)) < 0.001 {
            setPageOffset(CGFloat(target))
            return
        }
        pageAnimation = (pageOffset, CGFloat(target), ProcessInfo.processInfo.systemUptime, 0.28)
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stepPageAnimation()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pageAnimationTimer = timer
    }

    private func stepPageAnimation() {
        guard let animation = pageAnimation else {
            stopPageAnimation()
            return
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - animation.start
        let progress = min(1, elapsed / animation.duration)
        let eased = 1 - pow(1 - progress, 3) // ease-out cubic
        setPageOffset(animation.from + (animation.to - animation.from) * CGFloat(eased))
        if progress >= 1 {
            AppLog.debug("page.go finished at \(pageOffset)")
            stopPageAnimation()
        }
    }

    private func stopPageAnimation() {
        pageAnimationTimer?.invalidate()
        pageAnimationTimer = nil
        pageAnimation = nil
    }

    private func setPageOffset(_ value: CGFloat) {
        pageOffset = value
        layout.pageOffset = value
        indicator.currentPage = min(max(0, Int(value.rounded())), pageCount - 1)
        updateRecentStripVisibility(animated: false)
    }

    private func clampPageOffset() {
        let target = min(max(0, pageOffset), CGFloat(pageCount - 1))
        if abs(target - pageOffset) > 0.001 {
            setPageOffset(target)
        }
    }

    /// Wheel / trackpad handling.
    ///
    /// The mouse wheel flips one page per notch.
    ///
    /// Trackpad gestures are live-following: the page grid tracks the fingers and
    /// snaps to the nearest page when the gesture (including momentum) ends.
    ///
    /// Direction: `scrollingDelta` values carry "the content movement the system
    /// wants for the user's scrolling preference" — the same convention for
    /// trackpads and wheels, on both axes, in both natural and classic modes. The
    /// page offset therefore moves by *minus* the delta (content moving right means
    /// the view moves towards earlier pages), and the discrete wheel uses the same
    /// sign (positive delta = earlier page).
    private func handleScrollEvent(_ event: NSEvent) {
        // While a folder is open, wheel/gesture input scrolls the folder instead
        // of flipping pages.
        if folderOverlay.isPresented {
            folderOverlay.scrollWheel(with: event)
            return
        }
        guard pageCount > 1 else { return }

        if event.hasPreciseScrollingDeltas {
            handleTrackpadEvent(event)
        } else {
            handleDiscreteWheel(event)
        }
    }

    private func handleTrackpadEvent(_ event: NSEvent) {
        // Start (or lazily adopt) the gesture. A new gesture interrupts any page
        // animation so the drag feels immediate.
        if event.phase == .began || (event.phase == .changed && !gestureActive) {
            stopPageAnimation()
            cancelGestureSnap()
            gestureActive = true
            gestureBaseOffset = pageOffset
            gestureTravel = 0
        }
        guard gestureActive else { return }
        cancelGestureSnap()

        let delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX
            : event.scrollingDeltaY
        gestureTravel += -delta

        let maxOffset = CGFloat(pageCount - 1)
        let rawOffset = gestureBaseOffset + gestureTravel / max(1, layout.pageWidth)
        setPageOffset(min(max(0, rawOffset), maxOffset))

        if event.phase == .ended || event.phase == .cancelled {
            if event.momentumPhase == [] {
                scheduleGestureSnap(after: 0.06)
            }
        }
        if event.momentumPhase == .ended {
            scheduleGestureSnap(after: 0.02)
        }
    }

    private func handleDiscreteWheel(_ event: NSEvent) {
        // A pending trackpad gesture must not absorb wheel notches.
        if gestureActive {
            finishGesture()
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= wheelCooldownUntil, !isPageAnimating else { return }
        let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
        guard delta != 0 else { return }
        wheelCooldownUntil = now + 0.24
        go(toPage: currentPage + (delta > 0 ? -1 : 1), animated: true)
    }

    private func scheduleGestureSnap(after delay: TimeInterval) {
        cancelGestureSnap()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.finishGesture()
            }
        }
        gestureSnapWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func cancelGestureSnap() {
        gestureSnapWorkItem?.cancel()
        gestureSnapWorkItem = nil
    }

    /// Ends the live-follow gesture and snaps to the nearest page.
    private func finishGesture() {
        guard gestureActive else { return }
        gestureActive = false
        gestureTravel = 0
        let target = min(max(0, Int(pageOffset.rounded())), pageCount - 1)
        go(toPage: target, animated: true)
    }

    private func configureSearchField() {
        searchField.placeholderString = L10n.search
        searchField.font = .systemFont(ofSize: 14)
        searchField.focusRingType = .none
        searchField.maximumRecents = 0
        searchField.delegate = self
    }

    private func configureIndicator() {
        indicator.onSelectPage = { [weak self] page in
            self?.go(toPage: page, animated: true)
        }
        indicator.onBackgroundClick = { [weak self] in
            self?.requestCloseFromBackground()
        }
    }

    /// Background clicks close the panel — except while the built-in smoke test
    /// runs (stray system mouse-ups from the test harness would end the test).
    private func requestCloseFromBackground() {
        guard !probeIgnoresBackgroundClose else { return }
        guard !folderOverlay.isPresented else { return }
        onRequestClose?()
    }

    private func configureFolderOverlay() {
        folderOverlay.onClose = { [weak self] in
            guard let self else { return }
            self.folderOverlay.dismiss(animated: true)
            self.focusSearchField()
        }
        folderOverlay.onLaunchApp = { [weak self] app in
            self?.launch(app)
        }
        folderOverlay.onMoveOut = { [weak self] app in
            self?.moveAppOutOfFolder(app)
        }
        folderOverlay.onReorder = { [weak self] app, targetApp in
            self?.reorderAppInFolder(app, before: targetApp)
        }
        folderOverlay.onRename = { [weak self] name in
            self?.renamePresentedFolder(name)
        }
    }

    // MARK: - Presentation (driven by the window controller)

    func prepareForPresentation(screen: NSScreen) {
        _ = view // force load
        recentItems = Preferences.shared.showRecentApps ? recentAppsStore.recentApps(from: catalog.apps) : []
        // Reserve room for the recently-used strip only when it will be shown, and
        // only at presentation time, so the grid never shifts while open.
        metrics = .compute(for: screen.frame.size, extraTopInset: recentItems.isEmpty ? 0 : 84)
        backingScale = screen.backingScaleFactor
        layout.metrics = metrics
        layout.pageWidth = screen.frame.width
        recentStrip.update(items: recentItems, iconStore: iconStore, backingScale: backingScale)

        searchField.stringValue = ""
        searchQuery = ""
        folderOverlay.dismiss(animated: false)
        rebuildDisplayCells()
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()

        stopPageAnimation()
        setPageOffset(0)
        selectFirst()
    }

    func animateContentIn() {
        guard let layer = contentContainer.layer else { return }
        layer.opacity = 1
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.96
        scale.toValue = 1.0
        scale.duration = 0.24
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(scale, forKey: "present-scale")

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.0
        fade.toValue = 1.0
        fade.duration = 0.18
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "present-fade")
    }

    func animateContentOut(completion: @escaping () -> Void) {
        guard let layer = contentContainer.layer else {
            completion()
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                layer.opacity = 1
                completion()
            }
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? 1.0
        fade.toValue = 0.0
        fade.duration = 0.12
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        layer.add(fade, forKey: "dismiss-fade")
        layer.opacity = 0
        CATransaction.commit()
    }

    func prepareForDismissal() {
        folderOverlay.dismiss(animated: false)
        clearDropVisuals()
        contentContainer.layer?.removeAllAnimations()
        dismissKeyboardFocus()
    }

    func didDismiss() {
        collectionView.selectionIndexPaths = []
    }

    func focusSearchField() {
        view.window?.makeFirstResponder(searchField)
    }

    private func dismissKeyboardFocus() {
        if view.window?.firstResponder is NSTextView {
            view.window?.makeFirstResponder(nil)
        }
    }

    /// Called by the app layer when the catalog changed (apps installed/removed).
    func contentChanged() {
        guard isViewLoaded, view.window?.isVisible == true else { return }
        rebuildDisplayCells(preservingSelection: true)
    }

    /// Called by the app layer when another application became active.
    func refreshRecentApps() {
        guard isViewLoaded else { return }
        let items = Preferences.shared.showRecentApps ? recentAppsStore.recentApps(from: catalog.apps) : []
        guard items.map(\.bundleID) != recentItems.map(\.bundleID) else { return }
        recentItems = items
        recentStrip.update(items: items, iconStore: iconStore, backingScale: backingScale)
        updateRecentStripVisibility(animated: true)
    }

    private func removeFromRecents(_ app: AppItem) {
        recentAppsStore.remove(app.bundleID)
        refreshRecentApps()
    }

    /// The strip is shown on the first page only, never while searching.
    private func updateRecentStripVisibility(animated: Bool) {
        let shouldShow = !isSearching && currentPage == 0 && !recentItems.isEmpty
        let desiredHidden = !shouldShow
        guard recentStrip.isHidden != desiredHidden else { return }
        recentStrip.isHidden = desiredHidden
        if shouldShow, animated, let layer = recentStrip.layer {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.0
            fade.toValue = 1.0
            fade.duration = 0.18
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(fade, forKey: "recent-fade")
        }
    }

    // MARK: - Cell data

    private func rebuildDisplayCells(preservingSelection: Bool = false) {
        let selectedID = preservingSelection ? selectionID() : nil
        displayCells = isSearching ? searchResults() : gridCells()

        layout.itemCount = displayCells.count
        collectionView.reloadData()
        layout.invalidateLayout()
        indicator.pageCount = pageCount
        if displayCells.isEmpty {
            if isSearching {
                emptyStateLabel.stringValue = L10n.noMatchingApps
                emptyStateLabel.isHidden = false
            } else if catalog.hasCompletedDirectoryScan {
                emptyStateLabel.stringValue = L10n.noAppsFound
                emptyStateLabel.isHidden = false
            } else {
                emptyStateLabel.stringValue = L10n.scanningApps
                emptyStateLabel.isHidden = false
            }
        } else {
            emptyStateLabel.isHidden = true
        }
        if pageOffset > CGFloat(pageCount - 1) {
            stopPageAnimation()
            setPageOffset(CGFloat(pageCount - 1))
        }

        if let selectedID, let index = displayCells.firstIndex(where: { $0.id == selectedID }) {
            selectItem(at: index, scrollToPage: false)
        } else {
            selectFirst()
        }
    }

    private func selectionID() -> String? {
        guard let item = collectionView.selectionIndexPaths.first?.item, displayCells.indices.contains(item) else {
            return nil
        }
        return displayCells[item].id
    }

    private func appsByID() -> [String: AppItem] {
        var result: [String: AppItem] = [:]
        for app in catalog.apps { result[app.bundleID] = app }
        return result
    }

    private func gridCells() -> [LaunchpadCellModel] {
        let apps = appsByID()
        var cells: [LaunchpadCellModel] = []
        for item in layoutState.model.items {
            switch item {
            case .app(let id):
                if let app = apps[id], !hiddenAppsStore.contains(id) {
                    cells.append(LaunchpadCellModel(kind: .app(app)))
                }
            case .folder(let folder):
                let members = folder.appIDs.compactMap { apps[$0] }.filter { !hiddenAppsStore.contains($0.bundleID) }
                if members.count >= 2 {
                    cells.append(LaunchpadCellModel(kind: .folder(folder, members: members)))
                } else {
                    // Between reconciliations a folder can momentarily hold one
                    // member; show it as a plain app rather than losing it.
                    for member in members {
                        cells.append(LaunchpadCellModel(kind: .app(member)))
                    }
                }
            }
        }
        return cells
    }

    private func searchResults() -> [LaunchpadCellModel] {
        let apps = appsByID()
        let query = searchQuery
        var cells: [LaunchpadCellModel] = []
        var insideFolders = Set<String>()

        for item in layoutState.model.items {
            guard case .folder(let folder) = item else { continue }
            let members = folder.appIDs.compactMap { apps[$0] }.filter { !hiddenAppsStore.contains($0.bundleID) }
            members.forEach { insideFolders.insert($0.bundleID) }
            guard members.count >= 2 else { continue }
            let nameMatches = SearchMatcher.matches(name: folder.name, query: query)
            let memberMatches = members.contains { SearchMatcher.matches(name: $0.name, pinyin: $0.pinyinIndex, query: query) }
            if nameMatches || memberMatches {
                cells.append(LaunchpadCellModel(kind: .folder(folder, members: members)))
            }
        }

        for app in catalog.apps
        where !insideFolders.contains(app.bundleID) && !hiddenAppsStore.contains(app.bundleID) {
            if SearchMatcher.matches(name: app.name, pinyin: app.pinyinIndex, query: query) {
                cells.append(LaunchpadCellModel(kind: .app(app)))
            }
        }
        return cells
    }

    // MARK: - Search

    private func applySearch(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed != searchQuery else { return }
        searchQuery = trimmed
        rebuildDisplayCells()
        stopPageAnimation()
        setPageOffset(0)
        selectFirst()
    }

    // MARK: - Keyboard

    private func handleFallbackKeyDown(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 { // Esc
            handleEscape()
            return true
        }
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let characters = event.characters, !characters.isEmpty,
           characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            focusSearchField()
            searchField.stringValue += characters
            applySearch(searchField.stringValue)
            return true
        }
        return false
    }

    private func handleEscape() {
        if folderOverlay.isPresented {
            folderOverlay.dismiss(animated: true)
            focusSearchField()
            return
        }
        if !searchQuery.isEmpty {
            searchField.stringValue = ""
            applySearch("")
            return
        }
        onRequestClose?()
    }

    private func moveSelection(deltaColumn: Int, deltaRow: Int) {
        // While a folder is open the arrow keys navigate inside it.
        if folderOverlay.isPresented {
            folderOverlay.moveSelection(deltaColumn: deltaColumn, deltaRow: deltaRow)
            return
        }
        guard !displayCells.isEmpty else { return }
        guard let current = collectionView.selectionIndexPaths.first?.item else {
            selectFirst()
            return
        }

        let perPage = metrics.itemsPerPage
        let page = current / perPage
        let local = current % perPage
        var row = local / metrics.columns
        var column = local % metrics.columns
        var targetPage = page

        column += deltaColumn
        row += deltaRow

        if column >= metrics.columns {
            if page < layout.pageCount - 1 {
                targetPage += 1
                column = 0
            } else {
                column = metrics.columns - 1
            }
        } else if column < 0 {
            if page > 0 {
                targetPage -= 1
                column = metrics.columns - 1
            } else {
                column = 0
            }
        }
        row = min(max(row, 0), metrics.rows - 1)

        let slotsOnPage = min(perPage, displayCells.count - targetPage * perPage)
        guard slotsOnPage > 0 else { return }
        let slot = row * metrics.columns + column
        let target = targetPage * perPage + min(slot, slotsOnPage - 1)

        selectItem(at: target, scrollToPage: true)
    }

    private func selectFirst() {
        guard !displayCells.isEmpty else {
            collectionView.selectionIndexPaths = []
            return
        }
        selectItem(at: 0, scrollToPage: false)
    }

    private func selectItem(at index: Int, scrollToPage: Bool) {
        guard displayCells.indices.contains(index) else { return }
        desiredSelectionIndex = index
        collectionView.selectionIndexPaths = [IndexPath(item: index, section: 0)]
        if scrollToPage {
            go(toPage: metrics.page(ofItem: index), animated: true)
        }
    }

    // MARK: - Activation

    private func activateSelection() {
        if folderOverlay.isPresented {
            folderOverlay.activateSelected()
            return
        }
        guard !displayCells.isEmpty else { return }
        let index = collectionView.selectionIndexPaths.first?.item ?? 0
        activateCell(at: index)
    }

    func activateCell(at index: Int) {
        guard displayCells.indices.contains(index) else { return }
        switch displayCells[index].kind {
        case .app(let app):
            launch(app)
        case .folder(let folder, let members):
            folderOverlay.present(folder: folder, members: members, iconStore: iconStore, backingScale: backingScale)
        }
    }

    private func launch(_ app: AppItem) {
        // Prefer activating an already running instance over launching a new one.
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
            .first(where: { !$0.isTerminated }),
           running.activate() {
            onAppLaunched?()
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: app.url, configuration: configuration) { [weak self] _, error in
            Task { @MainActor in
                if let error {
                    NSLog("[ZhiyuLaunch] failed to open \(app.url.path): \(error)")
                }
                self?.onAppLaunched?()
            }
        }
    }

    // MARK: - Folder mutations

    private func folderMembers(_ folder: LayoutFolder) -> [AppItem] {
        let apps = appsByID()
        return folder.appIDs.compactMap { apps[$0] }
    }

    private func moveAppOutOfFolder(_ app: AppItem) {
        guard let folderID = folderOverlay.folderID else { return }
        layoutState.mutate { $0.remove(appID: app.bundleID, fromFolder: folderID) }
        refreshAfterFolderMutation(folderID: folderID)
    }

    private func reorderAppInFolder(_ app: AppItem, before targetApp: AppItem) {
        guard let folderID = folderOverlay.folderID else { return }
        layoutState.mutate { $0.moveInFolder(folderID: folderID, appID: app.bundleID, before: targetApp.bundleID) }
        refreshAfterFolderMutation(folderID: folderID)
    }

    private func renamePresentedFolder(_ name: String) {
        guard let folderID = folderOverlay.folderID else { return }
        layoutState.mutate { $0.rename(folderID: folderID, to: name) }
        refreshAfterFolderMutation(folderID: folderID, represent: false)
    }

    private func refreshAfterFolderMutation(folderID: UUID, represent: Bool = true) {
        rebuildDisplayCells(preservingSelection: true)

        guard let folder = layoutState.model.folder(id: folderID) else {
            folderOverlay.dismiss(animated: true)
            focusSearchField()
            return
        }
        let members = folderMembers(folder)
        if members.count < 2 || !folderOverlay.isPresented {
            folderOverlay.dismiss(animated: true)
            focusSearchField()
        } else if represent {
            folderOverlay.present(folder: folder, members: members, iconStore: iconStore, backingScale: backingScale)
        }
    }

    private func layoutRef(for cell: LaunchpadCellModel) -> LayoutItemRef? {
        switch cell.kind {
        case .app(let app): return .app(app.bundleID)
        case .folder(let folder, _): return .folder(folder.id)
        }
    }

    // MARK: - Context menu

    private var contextMenuCellIndex: Int?

    private func makeContextMenu(for index: Int) -> NSMenu? {
        guard displayCells.indices.contains(index) else { return nil }
        contextMenuCellIndex = index
        let menu = NSMenu()

        switch displayCells[index].kind {
        case .app:
            menu.addItem(withTitle: L10n.open, action: #selector(contextMenuOpen), keyEquivalent: "")
            menu.addItem(withTitle: L10n.revealInFinder, action: #selector(contextMenuReveal), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: L10n.hideApp, action: #selector(contextMenuHide), keyEquivalent: "")
        case .folder:
            menu.addItem(withTitle: L10n.open, action: #selector(contextMenuOpen), keyEquivalent: "")
            menu.addItem(withTitle: L10n.rename, action: #selector(contextMenuRename), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: L10n.dissolveFolder, action: #selector(contextMenuDissolve), keyEquivalent: "")
        }
        for item in menu.items {
            item.target = self
        }
        return menu
    }

    @objc private func contextMenuOpen() {
        guard let index = contextMenuCellIndex else { return }
        activateCell(at: index)
    }

    @objc private func contextMenuReveal() {
        guard let index = contextMenuCellIndex,
              displayCells.indices.contains(index),
              let app = displayCells[index].appItem else { return }
        NSWorkspace.shared.activateFileViewerSelecting([app.url])
    }

    @objc private func contextMenuRename() {
        guard let index = contextMenuCellIndex,
              displayCells.indices.contains(index),
              case .folder(let folder, let members) = displayCells[index].kind else { return }
        folderOverlay.present(folder: folder, members: members, iconStore: iconStore, backingScale: backingScale)
        folderOverlay.beginTitleEditing()
    }

    @objc private func contextMenuHide() {
        guard let index = contextMenuCellIndex,
              displayCells.indices.contains(index),
              let app = displayCells[index].appItem else { return }
        hiddenAppsStore.hide(app.bundleID)
        rebuildDisplayCells(preservingSelection: true)
    }

    @objc private func contextMenuDissolve() {
        guard let index = contextMenuCellIndex,
              displayCells.indices.contains(index),
              let folder = displayCells[index].folderValue else { return }
        layoutState.mutate { $0.dissolve(folderID: folder.id) }
        rebuildDisplayCells(preservingSelection: true)
    }

    // MARK: - Drop visuals

    private func showDropLine(forInsertAt index: Int) {
        let viewportHeight = collectionView.bounds.height
        guard viewportHeight > 0 else { return }

        let rect: NSRect
        if displayCells.indices.contains(index) {
            let frame = layout.frame(forItem: index, viewportHeight: viewportHeight)
            rect = NSRect(
                x: frame.minX - metrics.columnGap / 2 - 1.5,
                y: frame.minY + 10,
                width: 3,
                height: max(20, frame.height - 20)
            )
        } else if let lastIndex = displayCells.indices.last {
            let frame = layout.frame(forItem: lastIndex, viewportHeight: viewportHeight)
            rect = NSRect(
                x: frame.maxX + metrics.columnGap / 2 - 1.5,
                y: frame.minY + 10,
                width: 3,
                height: max(20, frame.height - 20)
            )
        } else {
            return
        }

        dropLine.frame = contentContainer.convert(rect, from: collectionView)
        dropLine.isHidden = false
    }

    private func hideDropLine() {
        dropLine.isHidden = true
    }

    private func highlightDropTarget(at index: Int?) {
        for item in collectionView.visibleItems() {
            (item as? AppCell)?.setDropTarget(false)
        }
        if let index, let item = collectionView.item(at: IndexPath(item: index, section: 0)) as? AppCell {
            item.setDropTarget(true)
        }
    }

    private func clearDropVisuals() {
        hideDropLine()
        highlightDropTarget(at: nil)
    }

    // MARK: - Drag-over edge flipping

    /// Parking the pointer near the left/right screen edge while dragging flips
    /// pages so items can be moved across pages.
    private var edgeFlipWorkItem: DispatchWorkItem?
    private var edgeFlipDirection = 0
    private static let edgeFlipMargin: CGFloat = 80
    private static let edgeFlipDelay: TimeInterval = 0.6

    private func updateEdgeFlip(for point: NSPoint) {
        let width = collectionView.bounds.width
        if point.x < Self.edgeFlipMargin {
            scheduleEdgeFlip(direction: -1)
        } else if point.x > width - Self.edgeFlipMargin {
            scheduleEdgeFlip(direction: 1)
        } else {
            cancelEdgeFlip()
        }
    }

    private func scheduleEdgeFlip(direction: Int) {
        if edgeFlipDirection == direction, edgeFlipWorkItem != nil { return }
        cancelEdgeFlip()
        edgeFlipDirection = direction
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.performEdgeFlip()
            }
        }
        edgeFlipWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.edgeFlipDelay, execute: item)
    }

    private func cancelEdgeFlip() {
        edgeFlipWorkItem?.cancel()
        edgeFlipWorkItem = nil
        edgeFlipDirection = 0
    }

    private func performEdgeFlip() {
        edgeFlipWorkItem = nil
        let direction = edgeFlipDirection
        guard direction != 0, view.window?.isVisible == true, !folderOverlay.isPresented else {
            edgeFlipDirection = 0
            return
        }
        let target = currentPage + direction
        guard target >= 0, target < pageCount else {
            edgeFlipDirection = 0
            return
        }
        go(toPage: target, animated: true)
        // Keep flipping while the pointer stays parked on the edge.
        scheduleEdgeFlip(direction: direction)
    }
}

// MARK: - NSCollectionViewDataSource

extension LaunchpadViewController: NSCollectionViewDataSource {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        displayCells.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: AppCell.reuseIdentifier, for: indexPath)
        if let cell = item as? AppCell, displayCells.indices.contains(indexPath.item) {
            cell.configure(
                with: displayCells[indexPath.item],
                metrics: metrics,
                backingScale: backingScale,
                isDark: isDarkAppearance,
                iconStore: iconStore
            )
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard !isSearching, displayCells.indices.contains(indexPath.item) else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(indexPath.item), forType: .zhiyuGridItem)
        return item
    }
}

// MARK: - NSCollectionViewDelegate (drag & drop)

extension LaunchpadViewController: NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
        !isSearching
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint,
        forItemsAt indexPaths: Set<IndexPath>
    ) {
        dragSourceIndex = indexPaths.first?.item
        (collectionView as? LaunchpadCollectionView)?.isDragSessionActive = true
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        draggingSession session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        dragOperation operation: NSDragOperation
    ) {
        dragSourceIndex = nil
        dropPlan = nil
        clearDropVisuals()
        cancelEdgeFlip()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            self?.collectionView.isDragSessionActive = false
        }
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        draggingSession session: NSDraggingSession,
        sourceOperationMaskForDraggingContext context: NSDraggingContext
    ) -> NSDragOperation {
        .move
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        validateDrop draggingInfo: NSDraggingInfo,
        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
    ) -> NSDragOperation {
        guard !isSearching,
              let sourceIndex = dragSourceIndex,
              displayCells.indices.contains(sourceIndex) else {
            dropPlan = nil
            clearDropVisuals()
            return []
        }

        let point = collectionView.convert(draggingInfo.draggingLocation, from: nil)
        updateEdgeFlip(for: point)
        let proposed = proposedDropIndexPath.pointee as IndexPath
        let plan = computeDropPlan(pointInCollection: point, sourceIndex: sourceIndex, proposedIndex: proposed.item)
        dropPlan = plan

        switch plan {
        case .insertBefore(let index):
            highlightDropTarget(at: nil)
            showDropLine(forInsertAt: index)
            proposedDropOperation.pointee = .before
            return .move
        case .intoCell(let index):
            hideDropLine()
            highlightDropTarget(at: index)
            proposedDropOperation.pointee = .on
            return .move
        }
    }

    /// Shared drop planning: hovering the middle of another app icon creates a
    /// folder (or adds to a folder); hovering its edges reorders.
    private func computeDropPlan(pointInCollection point: NSPoint, sourceIndex: Int, proposedIndex: Int?) -> DropPlan {
        let count = displayCells.count
        if let hitIndex = collectionView.itemIndexAtPoint?(point),
           displayCells.indices.contains(hitIndex),
           hitIndex != sourceIndex {
            let frame = layout.frame(forItem: hitIndex, viewportHeight: collectionView.bounds.height)
            let center = frame.insetBy(dx: frame.width * 0.24, dy: frame.height * 0.24)
            if center.contains(point), displayCells[sourceIndex].appItem != nil {
                return .intoCell(hitIndex)
            }
            return .insertBefore(point.x < frame.midX ? hitIndex : min(hitIndex + 1, count))
        }
        return .insertBefore(min(max(0, proposedIndex ?? count), count))
    }

    /// Shared drop application: mutates the layout and rebuilds the grid.
    private func applyDrop(_ plan: DropPlan, sourceIndex: Int) -> Bool {
        guard displayCells.indices.contains(sourceIndex),
              let sourceRef = layoutRef(for: displayCells[sourceIndex]) else { return false }

        var changed = false
        switch plan {
        case .insertBefore(let index):
            var targetRef: LayoutItemRef?
            if index < displayCells.count {
                targetRef = layoutRef(for: displayCells[index])
            }
            if targetRef == sourceRef { return false }
            changed = layoutState.mutate { $0.move(sourceRef, before: targetRef) }

        case .intoCell(let index):
            guard displayCells.indices.contains(index),
                  let sourceApp = displayCells[sourceIndex].appItem else { return false }
            let targetCell = displayCells[index]
            if let targetFolder = targetCell.folderValue {
                changed = layoutState.mutate { $0.add(appID: sourceApp.bundleID, toFolder: targetFolder.id) }
            } else if let targetApp = targetCell.appItem {
                changed = layoutState.mutate { model in
                    model.createFolder(with: sourceApp.bundleID, onto: targetApp.bundleID) != nil
                }
            }
        }

        if changed {
            rebuildDisplayCells(preservingSelection: true)
        }
        return changed
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        acceptDrop draggingInfo: NSDraggingInfo,
        indexPath: IndexPath,
        dropOperation: NSCollectionView.DropOperation
    ) -> Bool {
        defer {
            dropPlan = nil
            clearDropVisuals()
        }
        guard !isSearching,
              let sourceIndex = dragSourceIndex,
              displayCells.indices.contains(sourceIndex),
              let plan = dropPlan else { return false }
        return applyDrop(plan, sourceIndex: sourceIndex)
    }
}

// MARK: - NSTextFieldDelegate (search field command forwarding)

extension LaunchpadViewController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        // IME composition in progress: wait for the committed text.
        if let editor = searchField.currentEditor() as? NSTextView, editor.hasMarkedText() { return }
        applySearch(searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // While an IME candidate window is up, arrows/Enter belong to the IME.
        let marked = textView.hasMarkedText()

        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            if marked { return false }
            activateSelection()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            handleEscape()
            return true
        case #selector(NSResponder.moveLeft(_:)):
            if marked { return false }
            moveSelection(deltaColumn: -1, deltaRow: 0)
            return true
        case #selector(NSResponder.moveRight(_:)), #selector(NSResponder.insertTab(_:)):
            if marked { return false }
            moveSelection(deltaColumn: 1, deltaRow: 0)
            return true
        case #selector(NSResponder.moveUp(_:)):
            if marked { return false }
            moveSelection(deltaColumn: 0, deltaRow: -1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            if marked { return false }
            moveSelection(deltaColumn: 0, deltaRow: 1)
            return true
        case #selector(NSResponder.moveToBeginningOfDocument(_:)), #selector(NSResponder.moveToBeginningOfLine(_:)),
             #selector(NSResponder.scrollToBeginningOfDocument(_:)):
            if marked { return false }
            guard !folderOverlay.isPresented else { return false }
            go(toPage: 0, animated: true)
            return true
        case #selector(NSResponder.moveToEndOfDocument(_:)), #selector(NSResponder.moveToEndOfLine(_:)),
             #selector(NSResponder.scrollToEndOfDocument(_:)):
            if marked { return false }
            guard !folderOverlay.isPresented else { return false }
            go(toPage: pageCount - 1, animated: true)
            return true
        case #selector(NSResponder.deleteBackward(_:)):
            return searchField.stringValue.isEmpty
        default:
            return false
        }
    }
}

// MARK: - Built-in QA probes

/// Snapshot of the controller state, used by the built-in UI smoke test.
struct LaunchpadProbeState {
    let cellCount: Int
    let query: String
    let currentPage: Int
    let pageCount: Int
    let selectedIndex: Int?
    let isFolderPresented: Bool
    let names: [String]
}

extension LaunchpadViewController {
    var probeState: LaunchpadProbeState {
        LaunchpadProbeState(
            cellCount: displayCells.count,
            query: searchQuery,
            currentPage: currentPage,
            pageCount: layout.pageCount,
            selectedIndex: collectionView.selectionIndexPaths.first?.item,
            isFolderPresented: folderOverlay.isPresented,
            names: displayCells.map(\.displayName)
        )
    }

    var probeFirstCellIsFolder: Bool {
        displayCells.first?.folderValue != nil
    }

    var probeCollectionView: LaunchpadCollectionView { collectionView }
    var probeIndicator: PageIndicatorView { indicator }
    var probeSearchField: NSSearchField { searchField }
    var probeSearchFieldEditor: NSTextView? { searchField.currentEditor() as? NSTextView }
    var probeFolderSelection: Int? { folderOverlay.selectedIndex }

    /// Frame of the cell in window coordinates, for synthesized clicks.
    func probeCellWindowFrame(at index: Int) -> NSRect? {
        let viewportHeight = collectionView.bounds.height
        guard viewportHeight > 0, displayCells.indices.contains(index) else { return nil }
        let rect = layout.frame(forItem: index, viewportHeight: viewportHeight)
        return collectionView.convert(rect, to: nil)
    }

    /// QA only: invokes the background-click close path directly (synthesized
    /// mouse-ups are not reliably routed by AppKit without a paired mouse-down).
    func probeBackgroundClick() {
        requestCloseFromBackground()
    }

    /// QA only: runs the full drop pipeline (plan + apply) without a drag session.
    @discardableResult
    func probePerformDrop(sourceIndex: Int, atWindowPoint windowPoint: NSPoint) -> Bool {
        guard !isSearching, displayCells.indices.contains(sourceIndex) else { return false }
        let pointInCollection = collectionView.convert(windowPoint, from: nil)
        let plan = computeDropPlan(pointInCollection: pointInCollection, sourceIndex: sourceIndex, proposedIndex: nil)

        let previousSource = dragSourceIndex
        dragSourceIndex = sourceIndex
        defer {
            dragSourceIndex = previousSource
            dropPlan = nil
            clearDropVisuals()
        }
        return applyDrop(plan, sourceIndex: sourceIndex)
    }

    /// QA only: feeds a point into the drag-over edge-flip logic.
    func probeUpdateEdgeFlip(atWindowPoint windowPoint: NSPoint) {
        updateEdgeFlip(for: collectionView.convert(windowPoint, from: nil))
    }

    var probeEdgeFlipPending: Bool { edgeFlipWorkItem != nil }

    var probeCellIDs: [String] { displayCells.map(\.id) }

    var probeRecentCount: Int { recentItems.count }

    var probeRecentStripVisible: Bool { !recentStrip.isHidden }

    /// QA only: hides the app at the given cell (same path as the context menu).
    func probeHideCell(at index: Int) {
        guard displayCells.indices.contains(index), let app = displayCells[index].appItem else { return }
        hiddenAppsStore.hide(app.bundleID)
        rebuildDisplayCells(preservingSelection: true)
    }

    /// QA only: restores all hidden apps.
    func probeUnhideAll() {
        hiddenAppsStore.unhideAll()
        rebuildDisplayCells(preservingSelection: true)
    }

    /// Rebuilds the grid from the current model (QA helper).
    func probeReload() {
        rebuildDisplayCells(preservingSelection: true)
    }

    /// Non-animated page jump (QA helper).
    func probeJumpNoAnimation(to page: Int) {
        go(toPage: page, animated: false)
    }
}

// MARK: - Drop plan

private enum DropPlan {
    /// Insert the dragged item before the given flat index.
    case insertBefore(Int)
    /// Drop onto the cell at the given flat index (folder creation / addition).
    case intoCell(Int)
}

// MARK: - Small views

/// Root view: background clicks close the launchpad, stray key presses are
/// forwarded to the search pipeline.
final class LaunchpadRootView: NSView {
    var onBackgroundClick: (() -> Void)?
    var onKeyDown: ((NSEvent) -> Bool)?

    override func mouseDown(with event: NSEvent) {
        onBackgroundClick?()
    }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }

    override var acceptsFirstResponder: Bool { true }
}

/// Visual effect view that never intercepts mouse events (the collection view
/// underneath handles clicks).
final class PassthroughEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Plain view that never intercepts mouse events.
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The thin insertion line shown while reordering.
final class DropLineView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
        layer?.cornerRadius = 1.5
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
