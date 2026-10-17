import CoreGraphics

/// Geometry for one page of the icon grid, derived purely from the screen size.
///
/// Kept as a standalone value type so the layout math is unit-testable and so the
/// collection view layout and the cells agree on a single source of truth.
struct GridMetrics: Sendable, Equatable {
    let columns: Int
    let rows: Int
    let cellSize: CGSize
    let iconSize: CGFloat
    let columnGap: CGFloat
    let rowGap: CGFloat
    let sideMargin: CGFloat
    /// Space reserved above the grid for the search field.
    let topInset: CGFloat
    /// Space reserved below the grid for the page indicator.
    let bottomInset: CGFloat

    var itemsPerPage: Int { columns * rows }

    /// Computes the grid for a screen. `extraTopInset` reserves room for the
    /// recently-used strip when it is shown (determined at presentation time so
    /// the grid never shifts while the panel is open).
    static func compute(for screenSize: CGSize, extraTopInset: CGFloat = 0) -> GridMetrics {
        let sideMargin = max(60, (screenSize.width * 0.06).rounded())
        let topInset: CGFloat = 96 + max(0, extraTopInset)
        let bottomInset: CGFloat = 80
        let usableWidth = screenSize.width - sideMargin * 2
        let usableHeight = screenSize.height - topInset - bottomInset

        let columnGap: CGFloat = 22
        let rowGap: CGFloat = 26

        var columns = Int(usableWidth / 168)
        columns = min(max(columns, 4), 8)
        var rows = Int(usableHeight / 135)
        rows = min(max(rows, 3), 6)

        let cellWidth = (usableWidth - CGFloat(columns - 1) * columnGap) / CGFloat(columns)
        let cellHeight = (usableHeight - CGFloat(rows - 1) * rowGap) / CGFloat(rows)
        let iconSize = min(min(cellWidth - 16, cellHeight - 46), 96).rounded(.down)

        return GridMetrics(
            columns: columns,
            rows: rows,
            cellSize: CGSize(width: cellWidth, height: cellHeight),
            iconSize: max(48, iconSize),
            columnGap: columnGap,
            rowGap: rowGap,
            sideMargin: sideMargin,
            topInset: topInset,
            bottomInset: bottomInset
        )
    }

    /// Splits an ordered list into pages of `itemsPerPage`.
    func pages<T>(of items: [T]) -> [[T]] {
        guard !items.isEmpty else { return [] }
        let per = itemsPerPage
        return stride(from: 0, to: items.count, by: per).map { start in
            Array(items[start..<min(start + per, items.count)])
        }
    }

    /// Page index for a flat item index.
    func page(ofItem index: Int) -> Int {
        max(0, index) / max(1, itemsPerPage)
    }

    /// Number of pages needed for `count` items (always at least 1 when non-empty, 0 when empty).
    func pageCount(forItemCount count: Int) -> Int {
        guard count > 0 else { return 0 }
        return Int((Double(count) / Double(max(1, itemsPerPage))).rounded(.up))
    }
}
