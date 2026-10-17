import AppKit

/// The classic page dots at the bottom of the grid.
final class PageIndicatorView: NSView {
    var pageCount: Int = 1 {
        didSet {
            if pageCount != oldValue {
                currentPage = min(currentPage, max(0, pageCount - 1))
                needsDisplay = true
            }
        }
    }

    var currentPage: Int = 0 {
        didSet {
            if currentPage != oldValue { needsDisplay = true }
        }
    }

    /// Clicking a dot jumps to that page.
    var onSelectPage: ((Int) -> Void)?
    /// Clicking the band outside the dots behaves like a background click.
    var onBackgroundClick: (() -> Void)?

    private let dotSize: CGFloat = 7
    private let spacing: CGFloat = 10

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only take clicks when paging is actually possible.
        guard pageCount > 1 else { return nil }
        return super.hitTest(point)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let dotsWidth = dotsTotalWidth
        let originX = ((bounds.width - dotsWidth) / 2).rounded()

        guard point.x >= originX - spacing, point.x <= originX + dotsWidth + spacing else {
            onBackgroundClick?()
            return
        }
        let index = Int(((point.x - originX) / (dotSize + spacing)).rounded(.down))
        onSelectPage?(min(max(0, index), pageCount - 1))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard pageCount > 1 else { return }
        let originX = ((bounds.width - dotsTotalWidth) / 2).rounded()
        let originY = ((bounds.height - dotSize) / 2).rounded()

        for index in 0..<pageCount {
            let rect = NSRect(
                x: originX + CGFloat(index) * (dotSize + spacing),
                y: originY,
                width: dotSize,
                height: dotSize
            )
            let color = index == currentPage
                ? NSColor.white.withAlphaComponent(0.95)
                : NSColor.white.withAlphaComponent(0.35)
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
        }
    }

    private var dotsTotalWidth: CGFloat {
        CGFloat(pageCount) * dotSize + CGFloat(max(0, pageCount - 1)) * spacing
    }

    /// QA only: triggers the selection callback without synthesizing a mouse event
    /// (synthesized mouse-ups without a paired mouse-down are not reliably routed
    /// by AppKit; real clicks always come as a down/up pair).
    func probeSelect(page: Int) {
        onSelectPage?(min(max(0, page), max(0, pageCount - 1)))
    }
}
