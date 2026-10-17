import AppKit

/// Custom collection view layout that arranges items in a grid of pages.
///
/// Paging model: the layout lays out **all pages horizontally** but positions them
/// relative to `pageOffset` (a continuous page position). The collection view only
/// materializes items whose frames intersect its visible rect, so only the current
/// page (plus the neighboring page during a transition) creates item views.
///
/// This deliberately does **not** rely on `NSScrollView`/`documentView` frame
/// management: with a custom layout, `NSCollectionView` rewrites its own frame from
/// a stale content size (`_resizeToFitContentAndClipView`) and every scroll offset
/// change gets clamped back to the origin. Driving the offset through the layout
/// removes that entire class of staleness bugs.
final class LaunchpadLayout: NSCollectionViewLayout {
    var metrics: GridMetrics = .compute(for: CGSize(width: 1440, height: 900)) {
        didSet { invalidateLayout() }
    }

    var itemCount: Int = 0 {
        didSet { if itemCount != oldValue { invalidateLayout() } }
    }

    /// Width of one page, i.e. the collection view's viewport width.
    var pageWidth: CGFloat = 1440 {
        didSet { if pageWidth != oldValue { invalidateLayout() } }
    }

    /// Continuous page position (0 = first page, 1.5 = halfway between pages 1 and 2).
    /// Animating this value is what flips pages.
    var pageOffset: CGFloat = 0 {
        didSet { if pageOffset != oldValue { invalidateLayout() } }
    }

    var pageCount: Int {
        metrics.pageCount(forItemCount: itemCount)
    }

    override var collectionViewContentSize: NSSize {
        // The viewport never scrolls: content size equals the visible size.
        let height = viewportHeight ?? collectionView?.bounds.height ?? 800
        return NSSize(width: max(pageWidth, 1), height: height)
    }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        guard itemCount > 0, pageWidth > 0, let viewportHeight else { return [] }
        let perPage = metrics.itemsPerPage
        guard perPage > 0 else { return [] }

        // Only pages around the current offset can intersect the viewport.
        let lower = max(0, Int(pageOffset.rounded(.down)) - 1)
        let upper = min(pageCount - 1, Int(pageOffset.rounded(.up)) + 1)
        guard lower <= upper else { return [] }

        var attributes: [NSCollectionViewLayoutAttributes] = []
        for page in lower...upper {
            let start = page * perPage
            let end = min(start + perPage, itemCount)
            guard start < end else { continue }
            for index in start..<end {
                attributes.append(self.attributes(for: index, viewportHeight: viewportHeight))
            }
        }
        return attributes
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard indexPath.item >= 0, indexPath.item < itemCount,
              let viewportHeight, pageWidth > 0 else { return nil }
        return attributes(for: indexPath.item, viewportHeight: viewportHeight)
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        false
    }

    // MARK: - Geometry

    private var viewportHeight: CGFloat? {
        if let view = collectionView, view.bounds.height > 0 {
            return view.bounds.height
        }
        return nil
    }

    /// Frame of the item in the collection view's flipped coordinate space,
    /// offset by the current `pageOffset`.
    func frame(forItem index: Int, viewportHeight: CGFloat) -> NSRect {
        let m = metrics
        let page = index / m.itemsPerPage
        let local = index % m.itemsPerPage
        let row = local / m.columns       // 0 = top row
        let column = local % m.columns

        let gridHeight = CGFloat(m.rows) * m.cellSize.height + CGFloat(m.rows - 1) * m.rowGap
        let usableHeight = viewportHeight - m.topInset - m.bottomInset
        let blockTop = m.topInset + (usableHeight - gridHeight) / 2

        let x = m.sideMargin
            + CGFloat(column) * (m.cellSize.width + m.columnGap)
            + (CGFloat(page) - pageOffset) * pageWidth
        let y = blockTop + CGFloat(row) * (m.cellSize.height + m.rowGap)
        return NSRect(x: x, y: y, width: m.cellSize.width, height: m.cellSize.height)
    }

    private func attributes(for index: Int, viewportHeight: CGFloat) -> NSCollectionViewLayoutAttributes {
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: index, section: 0))
        attributes.frame = frame(forItem: index, viewportHeight: viewportHeight)
        attributes.zIndex = 0
        return attributes
    }
}
