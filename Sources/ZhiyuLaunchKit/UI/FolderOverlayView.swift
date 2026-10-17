import AppKit

/// The expanded folder view, matching the classic Launchpad folder look:
/// a dimmed backdrop and a blurred rounded card with an editable title and a
/// grid of mini app tiles.
final class FolderOverlayView: NSView {
    var onClose: (() -> Void)?
    var onLaunchApp: ((AppItem) -> Void)?
    var onMoveOut: ((AppItem) -> Void)?
    var onReorder: ((AppItem, AppItem) -> Void)?
    var onRename: ((String) -> Void)?

    private(set) var isPresented = false
    private(set) var folderID: UUID?

    private let backdrop = BackdropView()
    private let card = FolderCardView()
    private let titleField = NSTextField()
    private let scrollView = NSScrollView()
    private let tilesContainer = NSView()
    private var tiles: [NSView] = []

    /// Apps currently shown in the folder (keyboard navigation source of truth).
    private var members: [AppItem] = []
    private(set) var selectedIndex: Int?

    private var iconStore: IconStore?
    private var backingScale: CGFloat = 2

    private let tileSize = NSSize(width: 92, height: 110)
    private let tileIconSize: CGFloat = 64
    private let padding: CGFloat = 30
    private let titleHeight: CGFloat = 34
    private let hGap: CGFloat = 10
    private let vGap: CGFloat = 8

    private var cardColumns = 3
    private var cardRows = 1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isHidden = true

        backdrop.onClick = { [weak self] in self?.onClose?() }
        addSubview(backdrop)

        card.material = .hudWindow
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 32
        card.layer?.masksToBounds = true
        addSubview(card)

        titleField.isEditable = true
        titleField.isSelectable = true
        titleField.isBordered = false
        titleField.isBezeled = false
        titleField.drawsBackground = false
        titleField.focusRingType = .none
        titleField.alignment = .center
        titleField.font = .systemFont(ofSize: 20, weight: .medium)
        titleField.textColor = .white
        titleField.placeholderString = LayoutFolder.defaultName
        titleField.lineBreakMode = .byTruncatingTail
        titleField.delegate = self
        titleField.target = self
        titleField.action = #selector(titleCommitted)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 3
        titleField.shadow = shadow
        card.addSubview(titleField)

        // The tile grid scrolls when a folder holds more apps than fit on screen.
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = tilesContainer
        card.addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Presentation

    func present(folder: LayoutFolder, members: [AppItem], iconStore: IconStore, backingScale: CGFloat) {
        self.iconStore = iconStore
        self.backingScale = backingScale
        self.folderID = folder.id
        titleField.stringValue = folder.name

        rebuildTiles(members: members)
        isHidden = false
        isPresented = true
        needsLayout = true
        layoutSubtreeIfNeeded()

        backdrop.alphaValue = 0
        card.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            backdrop.animator().alphaValue = 1
            card.animator().alphaValue = 1
        }
        if let layer = card.layer {
            let pop = CABasicAnimation(keyPath: "transform.scale")
            pop.fromValue = 0.86
            pop.toValue = 1.0
            pop.duration = 0.22
            pop.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(pop, forKey: "present")
        }
    }

    func dismiss(animated: Bool) {
        guard isPresented else { return }
        isPresented = false
        folderID = nil

        guard animated else {
            hideNow()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            backdrop.animator().alphaValue = 0
            card.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.hideNow()
            }
        })
    }

    private func hideNow() {
        isHidden = true
        tiles.forEach { $0.removeFromSuperview() }
        tiles = []
    }

    /// Focuses the folder title for immediate renaming (used by the grid context menu).
    func beginTitleEditing() {
        window?.makeFirstResponder(titleField)
        titleField.currentEditor()?.selectAll(nil)
    }

    // MARK: - Content

    private func rebuildTiles(members: [AppItem]) {
        self.members = members
        tiles.forEach { $0.removeFromSuperview() }
        tiles = []
        selectedIndex = nil
        scrollView.contentView.setBoundsOrigin(.zero)

        guard !members.isEmpty else { return }

        cardColumns = min(5, max(3, Int(Double(members.count).squareRoot().rounded(.up))))
        cardRows = max(1, Int((Double(members.count) / Double(cardColumns)).rounded(.up)))

        for member in members {
            let tile = MiniAppTile(app: member)
            tile.onActivate = { [weak self] app in self?.onLaunchApp?(app) }
            tile.onMoveOut = { [weak self] app in self?.onMoveOut?(app) }
            tile.onDragEnded = { [weak self] app, screenPoint in
                self?.handleDragEnded(app: app, screenPoint: screenPoint)
            }
            tile.onReveal = { app in
                NSWorkspace.shared.activateFileViewerSelecting([app.url])
            }
            tile.loadIcon(using: iconStore, pointSize: tileIconSize, scale: backingScale)
            tilesContainer.addSubview(tile)
            tiles.append(tile)
        }
    }

    // MARK: - Keyboard navigation

    /// Moves the selection inside the folder grid (used by the arrow keys while
    /// the folder is open).
    func moveSelection(deltaColumn: Int, deltaRow: Int) {
        guard !members.isEmpty else { return }
        let columns = cardColumns
        let current = selectedIndex ?? 0
        var row = current / columns
        var column = current % columns

        column += deltaColumn
        row += deltaRow
        if column >= columns { column = columns - 1 }
        if column < 0 { column = 0 }
        let maxRow = max(0, (members.count - 1) / columns)
        row = min(max(row, 0), maxRow)

        var target = row * columns + column
        if target >= members.count { target = members.count - 1 }
        setSelection(target)
    }

    func activateSelected() {
        guard let selectedIndex, members.indices.contains(selectedIndex) else { return }
        onLaunchApp?(members[selectedIndex])
    }

    private func setSelection(_ index: Int?) {
        selectedIndex = index
        for (tileIndex, tile) in tiles.enumerated() {
            guard let appTile = tile as? MiniAppTile else { continue }
            appTile.setSelected(tileIndex == index)
        }
        if let index, tiles.indices.contains(index) {
            scrollView.contentView.scrollToVisible(tiles[index].frame.insetBy(dx: 0, dy: -vGap))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    // MARK: - Scrolling and drag handling

    override func scrollWheel(with event: NSEvent) {
        // Wheel events over the card drive the folder's own scrolling instead of
        // page flipping.
        scrollView.scrollWheel(with: event)
    }

    /// Dragging a tile ends either outside the card (move the app back to the
    /// grid) or on another tile (reorder inside the folder).
    private func handleDragEnded(app: AppItem, screenPoint: NSPoint) {
        guard let window else { return }
        let cardOnScreen = window.convertToScreen(card.convert(card.bounds, to: nil))
        guard cardOnScreen.contains(screenPoint) else {
            onMoveOut?(app)
            return
        }

        let pointInWindow = window.convertPoint(fromScreen: screenPoint)
        let pointInCard = card.convert(pointInWindow, from: nil)
        let pointInTiles = tilesContainer.convert(pointInCard, from: card)
        for tile in tiles {
            guard let appTile = tile as? MiniAppTile,
                  appTile.app.bundleID != app.bundleID,
                  appTile.frame.contains(pointInTiles) else { continue }
            onReorder?(app, appTile.app)
            return
        }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        backdrop.frame = bounds

        let contentWidth = CGFloat(cardColumns) * tileSize.width + CGFloat(max(0, cardColumns - 1)) * hGap
        let contentHeight = CGFloat(cardRows) * tileSize.height + CGFloat(max(0, cardRows - 1)) * vGap

        // The card grows with the folder but never exceeds the screen; taller
        // content scrolls inside the card.
        let maxCardHeight = max(240, bounds.height - 140)
        let desiredHeight = contentHeight + padding * 2 + titleHeight
        let cardHeight = min(desiredHeight, maxCardHeight)
        let cardWidth = contentWidth + padding * 2

        card.frame = NSRect(
            x: ((bounds.width - cardWidth) / 2).rounded(),
            y: ((bounds.height - cardHeight) / 2).rounded(),
            width: cardWidth,
            height: cardHeight
        )
        titleField.frame = NSRect(
            x: 24,
            y: card.bounds.height - 14 - titleHeight,
            width: max(0, card.bounds.width - 48),
            height: titleHeight
        )

        let scrollHeight = max(0, card.bounds.height - padding * 2 - titleHeight)
        scrollView.frame = NSRect(x: padding, y: padding, width: contentWidth, height: scrollHeight)
        // The document is at least as tall as the clip so short folders stay pinned
        // to the top (rows are laid out downwards from the top).
        tilesContainer.frame = NSRect(x: 0, y: 0, width: contentWidth, height: max(contentHeight, scrollHeight))

        for (index, tile) in tiles.enumerated() {
            let column = index % cardColumns
            let row = index / cardColumns
            let x = CGFloat(column) * (tileSize.width + hGap)
            let y = tilesContainer.bounds.height - CGFloat(row + 1) * tileSize.height - CGFloat(row) * vGap
            tile.frame = NSRect(x: x, y: y, width: tileSize.width, height: tileSize.height)
        }
    }

    @objc private func titleCommitted() {
        commitRename()
    }

    private func commitRename() {
        onRename?(titleField.stringValue)
    }
}

// MARK: - NSTextFieldDelegate

extension FolderOverlayView: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        commitRename()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            // Stop editing without triggering anything else; a second Esc closes the folder.
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }
}

// MARK: - Supporting views

/// Dimmed background; a click anywhere on it closes the overlay.
private final class BackdropView: NSView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.3).setFill()
        dirtyRect.fill()
    }
}

/// The blurred card; swallows clicks so only the backdrop closes the overlay.
private final class FolderCardView: NSVisualEffectView {
    override func mouseDown(with event: NSEvent) {
        // Intentionally empty: clicks on the card's empty areas do nothing.
    }
}

/// One tappable app inside a folder.
private final class MiniAppTile: NSView {
    let app: AppItem
    var onActivate: ((AppItem) -> Void)?
    var onMoveOut: ((AppItem) -> Void)?
    var onReveal: ((AppItem) -> Void)?
    var onDragEnded: ((AppItem, NSPoint) -> Void)?

    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let iconSize: CGFloat = 64
    private var mouseDownPoint: NSPoint?
    private let selectionView = NSView()

    init(app: AppItem) {
        self.app = app
        super.init(frame: .zero)
        wantsLayer = true

        selectionView.wantsLayer = true
        selectionView.layer?.cornerRadius = 12
        selectionView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.22).cgColor
        selectionView.isHidden = true
        addSubview(selectionView)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.imageAlignment = .alignCenter
        addSubview(iconView)

        label.stringValue = app.name
        label.alignment = .center
        label.font = .systemFont(ofSize: 12)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.maximumNumberOfLines = 1
        label.isSelectable = false
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 3
        label.shadow = shadow
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setSelected(_ selected: Bool) {
        selectionView.isHidden = !selected
    }

    func loadIcon(using store: IconStore?, pointSize: CGFloat, scale: CGFloat) {
        guard let store else { return }
        let url = app.url
        let key = IconStore.appIconKey(url: url, pointSize: pointSize, scale: scale)
        if let hit = store.image(
            forKey: key,
            pointSize: pointSize,
            scale: scale,
            render: { IconStore.renderAppIcon(url: url, pointSize: pointSize, scale: scale) },
            completion: { [weak self] image in self?.iconView.image = image }
        ) {
            iconView.image = hit
        }
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let current = convert(event.locationInWindow, from: nil)
        guard hypot(current.x - start.x, current.y - start.y) > 4 else { return }
        mouseDownPoint = nil
        startDraggingSession(event)
    }

    private func startDraggingSession(_ event: NSEvent) {
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(app.bundleID, forType: .zhiyuGridItem)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let image = iconView.image ?? NSImage(size: NSSize(width: iconSize, height: iconSize))
        draggingItem.setDraggingFrame(
            NSRect(x: 0, y: 0, width: iconSize, height: iconSize),
            contents: image
        )
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        if event.buttonNumber == 0, mouseDownPoint != nil {
            onActivate?(app)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let open = NSMenuItem(title: L10n.open, action: #selector(activate), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let moveOut = NSMenuItem(title: L10n.moveOutOfFolder, action: #selector(moveOut), keyEquivalent: "")
        moveOut.target = self
        menu.addItem(moveOut)
        let reveal = NSMenuItem(title: L10n.revealInFinder, action: #selector(reveal), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)
        return menu
    }

    @objc private func activate() { onActivate?(app) }
    @objc private func moveOut() { onMoveOut?(app) }
    @objc private func reveal() { onReveal?(app) }

    override func layout() {
        super.layout()
        let bounds = self.bounds
        let iconRect = NSRect(
            x: ((bounds.width - iconSize) / 2).rounded(),
            y: bounds.height - 4 - iconSize,
            width: iconSize,
            height: iconSize
        )
        iconView.frame = iconRect
        selectionView.frame = iconRect.insetBy(dx: -8, dy: -8)
        label.frame = NSRect(x: 2, y: max(0, iconView.frame.minY - 6 - 16), width: bounds.width - 4, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {}
}

extension MiniAppTile: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDragEnded?(app, screenPoint)
    }
}

