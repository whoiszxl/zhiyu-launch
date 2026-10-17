import AppKit

/// The model for one grid cell: a plain app or a folder.
enum LaunchpadCellKind {
    case app(AppItem)
    case folder(LayoutFolder, members: [AppItem])
}

struct LaunchpadCellModel {
    let kind: LaunchpadCellKind

    /// Stable identity used to validate async icon loads in recycled cells.
    var id: String {
        switch kind {
        case .app(let app): return "app:\(app.bundleID)"
        case .folder(let folder, _): return "folder:\(folder.id.uuidString)"
        }
    }

    var displayName: String {
        switch kind {
        case .app(let app): return app.name
        case .folder(let folder, _): return folder.name
        }
    }

    var appItem: AppItem? {
        if case .app(let app) = kind { return app }
        return nil
    }

    var folderValue: LayoutFolder? {
        if case .folder(let folder, _) = kind { return folder }
        return nil
    }
}

/// One icon cell: icon image, label, keyboard-selection and drop highlight.
///
/// The cell view is fully transparent to mouse events (`hitTest` returns nil) so
/// `NSCollectionView` handles clicks, selection and drag sessions itself.
final class AppCell: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("AppCell")

    private var root: CellRootView { view as! CellRootView }

    private var representedID: String?
    private var dropTargeted = false

    override func loadView() {
        view = CellRootView()
    }

    override var isSelected: Bool {
        didSet { updateHighlight() }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedID = nil
        dropTargeted = false
        root.iconView.image = nil
        root.titleLabel.stringValue = ""
        updateHighlight()
    }

    func configure(
        with model: LaunchpadCellModel,
        metrics: GridMetrics,
        backingScale: CGFloat,
        isDark: Bool,
        iconStore: IconStore
    ) {
        representedID = model.id
        root.iconSize = metrics.iconSize
        root.titleLabel.stringValue = model.displayName
        root.iconView.image = nil
        root.needsLayout = true

        let pointSize = metrics.iconSize
        let scale = backingScale
        let requestID = model.id
        let completion: @MainActor (NSImage) -> Void = { [weak self] image in
            guard let self, self.representedID == requestID else { return }
            self.root.iconView.image = image
        }

        switch model.kind {
        case .app(let app):
            let url = app.url
            let key = IconStore.appIconKey(url: url, pointSize: pointSize, scale: scale)
            let hit = iconStore.image(
                forKey: key,
                pointSize: pointSize,
                scale: scale,
                render: { IconStore.renderAppIcon(url: url, pointSize: pointSize, scale: scale) },
                completion: completion
            )
            if let hit { root.iconView.image = hit }

        case .folder(_, let members):
            let urls = members.map(\.url)
            let key = IconStore.folderIconKey(appURLs: urls, pointSize: pointSize, scale: scale, isDark: isDark)
            let hit = iconStore.image(
                forKey: key,
                pointSize: pointSize,
                scale: scale,
                render: { IconStore.renderFolderIcon(appURLs: urls, pointSize: pointSize, scale: scale, isDark: isDark) },
                completion: completion
            )
            if let hit { root.iconView.image = hit }
        }
    }

    func setDropTarget(_ targeted: Bool) {
        guard dropTargeted != targeted else { return }
        dropTargeted = targeted
        updateHighlight()
    }

    private func updateHighlight() {
        root.highlightView.isHidden = !(isSelected || dropTargeted)
        root.highlightView.layer?.backgroundColor = dropTargeted
            ? NSColor.controlAccentColor.withAlphaComponent(0.4).cgColor
            : NSColor.white.withAlphaComponent(0.2).cgColor
    }
}

/// The cell's root view. `hitTest` returning nil keeps every mouse event flowing
/// to the collection view, which owns selection, clicking and drag & drop.
final class CellRootView: NSView {
    let highlightView = NSView()
    let iconView = NSImageView()
    let titleLabel = NSTextField(labelWithString: "")

    var iconSize: CGFloat = 72 {
        didSet { if iconSize != oldValue { needsLayout = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        highlightView.wantsLayer = true
        highlightView.layer?.cornerRadius = 14
        highlightView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        highlightView.isHidden = true

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.imageAlignment = .alignCenter

        titleLabel.alignment = .center
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.usesSingleLineMode = true
        titleLabel.maximumNumberOfLines = 1
        titleLabel.isSelectable = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        titleLabel.shadow = shadow

        addSubview(highlightView)
        addSubview(iconView)
        addSubview(titleLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        let bounds = self.bounds
        let labelHeight: CGFloat = 17
        let topPadding: CGFloat = 4

        let iconRect = NSRect(
            x: ((bounds.width - iconSize) / 2).rounded(),
            y: bounds.height - topPadding - iconSize,
            width: iconSize,
            height: iconSize
        )
        iconView.frame = iconRect
        highlightView.frame = iconRect.insetBy(dx: -9, dy: -9)
        titleLabel.frame = NSRect(
            x: 6,
            y: max(0, iconRect.minY - 5 - labelHeight),
            width: max(0, bounds.width - 12),
            height: labelHeight
        )
    }
}
