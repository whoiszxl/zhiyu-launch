import AppKit

extension NSPasteboard.PasteboardType {
    /// Drag payload for grid items (the index into the display cells).
    static let zhiyuGridItem = NSPasteboard.PasteboardType("com.zhiyu.launch.grid-item")
}

/// Collection view subclass that reports clicks and scroll gestures to the
/// controller and keeps its own mouse handling out of the way during drag sessions.
///
/// The view refuses first responder status on purpose: keyboard input must always
/// stay with the search field (which handles IME correctly); navigation commands
/// are forwarded from the search field delegate instead.
final class LaunchpadCollectionView: NSCollectionView {
    var onItemClick: ((IndexPath) -> Void)?
    var onBackgroundClick: (() -> Void)?
    /// Scroll wheel / trackpad events are interpreted by the controller, which
    /// owns the paging animation.
    var onScroll: ((NSEvent) -> Void)?
    /// Builds the context menu for the cell at the given flat index.
    var onContextMenu: ((Int) -> NSMenu?)?
    /// Pure-geometry hit test in the collection view's coordinate space. Used
    /// instead of `indexPathForItem(at:)` so clicks work even before an item's
    /// view has been materialized.
    var itemIndexAtPoint: ((NSPoint) -> Int?)?
    var isDragSessionActive = false

    override var acceptsFirstResponder: Bool { false }

    override func mouseUp(with event: NSEvent) {
        if !isDragSessionActive {
            let point = convert(event.locationInWindow, from: nil)
            if let index = itemIndexAtPoint?(point) {
                onItemClick?(IndexPath(item: index, section: 0))
            } else {
                onBackgroundClick?()
            }
        }
        super.mouseUp(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = itemIndexAtPoint?(point) else { return nil }
        return onContextMenu?(index)
    }
}
