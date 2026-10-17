import AppKit

/// The "recently used" strip shown above the grid on the first page.
final class RecentAppsView: NSView {
    var onLaunch: ((AppItem) -> Void)?
    var onRemoveRecent: ((AppItem) -> Void)?

    private var buttons: [RecentAppButton] = []
    private let itemWidth: CGFloat = 78
    private let itemHeight: CGFloat = 68
    private let iconSize: CGFloat = 52
    private let spacing: CGFloat = 18
    private let maxVisible = 9

    /// Rebuilds the strip. Cheap: at most nine lightweight buttons.
    func update(items: [AppItem], iconStore: IconStore, backingScale: CGFloat) {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = []

        for item in items.prefix(maxVisible) {
            let button = RecentAppButton(app: item, iconSize: iconSize)
            button.onClick = { [weak self] app in self?.onLaunch?(app) }
            button.onRemoveRecent = { [weak self] app in self?.onRemoveRecent?(app) }
            button.loadIcon(using: iconStore, scale: backingScale)
            addSubview(button)
            buttons.append(button)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let count = buttons.count
        guard count > 0 else { return }
        let totalWidth = CGFloat(count) * itemWidth + CGFloat(count - 1) * spacing
        var x = ((bounds.width - totalWidth) / 2).rounded()
        let y = ((bounds.height - itemHeight) / 2).rounded()
        for button in buttons {
            button.frame = NSRect(x: x, y: y, width: itemWidth, height: itemHeight)
            x += itemWidth + spacing
        }
    }
}

/// One app in the recently-used strip.
private final class RecentAppButton: NSView {
    let app: AppItem
    var onClick: ((AppItem) -> Void)?
    var onRemoveRecent: ((AppItem) -> Void)?

    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let iconSize: CGFloat

    init(app: AppItem, iconSize: CGFloat) {
        self.app = app
        self.iconSize = iconSize
        super.init(frame: .zero)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.imageAlignment = .alignCenter
        addSubview(iconView)

        label.stringValue = app.name
        label.alignment = .center
        label.font = .systemFont(ofSize: 11)
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

    func loadIcon(using store: IconStore, scale: CGFloat) {
        let url = app.url
        let pointSize = iconSize
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

    override func mouseUp(with event: NSEvent) {
        if event.buttonNumber == 0 {
            onClick?(app)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let open = NSMenuItem(title: L10n.open, action: #selector(activate), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let reveal = NSMenuItem(title: L10n.revealInFinder, action: #selector(reveal), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)
        menu.addItem(.separator())
        let remove = NSMenuItem(title: L10n.removeFromRecents, action: #selector(removeRecent), keyEquivalent: "")
        remove.target = self
        menu.addItem(remove)
        return menu
    }

    @objc private func activate() { onClick?(app) }
    @objc private func reveal() { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
    @objc private func removeRecent() { onRemoveRecent?(app) }

    override func layout() {
        super.layout()
        let bounds = self.bounds
        iconView.frame = NSRect(
            x: ((bounds.width - iconSize) / 2).rounded(),
            y: bounds.height - 2 - iconSize,
            width: iconSize,
            height: iconSize
        )
        label.frame = NSRect(x: 0, y: max(0, iconView.frame.minY - 4 - 14), width: bounds.width, height: 14)
    }
}
