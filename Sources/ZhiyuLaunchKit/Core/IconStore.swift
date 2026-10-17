import AppKit
import Foundation

/// Renders and caches downscaled icon thumbnails.
///
/// Design notes:
/// - The system icon objects returned by `NSWorkspace` carry many representations
///   (up to 1024px); caching them as-is would waste tens of megabytes. We render a
///   single thumbnail at *exactly* the pixel size the grid needs.
/// - Rendering happens on a concurrent background queue; results hop back to the
///   main actor. Requests are de-duplicated per cache key.
/// - `NSCache` bounds the memory (count + cost) and evicts automatically.
@MainActor
final class IconStore {
    static let shared = IconStore()

    /// Transfers an `NSImage` created off-main; NSImage is thread-safe once fully initialized.
    private struct SendableImage: @unchecked Sendable { let image: NSImage? }

    private let cache = NSCache<NSString, NSImage>()
    private var inFlight: Set<String> = []
    private var waiters: [String: [@MainActor (NSImage) -> Void]] = [:]
    private let renderQueue = DispatchQueue(
        label: "com.zhiyu.launch.icon-render",
        qos: .userInitiated,
        attributes: .concurrent
    )

    init(countLimit: Int = 200, totalCostLimit: Int = 24 * 1024 * 1024) {
        cache.countLimit = countLimit
        cache.totalCostLimit = totalCostLimit
    }

    // MARK: - Public API

    /// Cache key for an app icon at a given pixel size.
    nonisolated static func appIconKey(url: URL, pointSize: CGFloat, scale: CGFloat) -> String {
        "app|\(url.path)|\(pixelSize(pointSize: pointSize, scale: scale))"
    }

    /// Cache key for a composed folder icon.
    nonisolated static func folderIconKey(appURLs: [URL], pointSize: CGFloat, scale: CGFloat, isDark: Bool) -> String {
        let paths = appURLs.map(\.path).joined(separator: ">")
        return "folder|\(pixelSize(pointSize: pointSize, scale: scale))|\(isDark ? "d" : "l")|\(paths.hashValue)"
    }

    /// Returns a cached thumbnail immediately, otherwise starts an async render and
    /// calls `completion` (main actor) when the image is ready.
    @discardableResult
    func image(
        forKey key: String,
        pointSize: CGFloat,
        scale: CGFloat,
        render: @escaping @Sendable () -> NSImage?,
        completion: (@MainActor (NSImage) -> Void)? = nil
    ) -> NSImage? {
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }

        if let completion {
            waiters[key, default: []].append(completion)
        }

        guard !inFlight.contains(key) else { return nil }
        inFlight.insert(key)

        let pixel = Self.pixelSize(pointSize: pointSize, scale: scale)
        let cost = pixel * pixel * 4
        renderQueue.async { [weak self] in
            // IconServices pulls in large temporary objects; drain them eagerly so
            // background renders don't inflate the process footprint.
            let box = autoreleasepool { SendableImage(image: render()) }
            Task { @MainActor [weak self] in
                self?.finish(key: key, result: box.image, cost: cost)
            }
        }
        return nil
    }

    func clear() {
        cache.removeAllObjects()
    }

    // MARK: - Renderers (nonisolated, safe to run on background queues)

    nonisolated static func renderAppIcon(url: URL, pointSize: CGFloat, scale: CGFloat) -> NSImage? {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        return makeThumbnail(from: icon, pointSize: pointSize, scale: scale)
    }

    /// Composes the classic Launchpad folder icon: a translucent rounded card with
    /// up to 9 app icons in a 3×3 grid.
    nonisolated static func renderFolderIcon(appURLs: [URL], pointSize: CGFloat, scale: CGFloat, isDark: Bool) -> NSImage? {
        let pixel = pixelSize(pointSize: pointSize, scale: scale)
        guard pixel >= 16,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixel,
                pixelsHigh: pixel,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              ) else { return nil }

        rep.size = NSSize(width: pointSize, height: pointSize)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high

        let full = NSRect(x: 0, y: 0, width: pointSize, height: pointSize)
        let card = NSBezierPath(roundedRect: full, xRadius: pointSize * 0.2, yRadius: pointSize * 0.2)
        let cardColor = isDark
            ? NSColor.white.withAlphaComponent(0.22)
            : NSColor.black.withAlphaComponent(0.14)
        cardColor.setFill()
        card.fill()

        let members = Array(appURLs.prefix(9))
        if !members.isEmpty {
            let inset = pointSize * 0.13
            let gridRect = full.insetBy(dx: inset, dy: inset)
            let iconSize = (gridRect.width - pointSize * 0.06) / 3
            let step = iconSize + pointSize * 0.03
            for (index, url) in members.enumerated() {
                let column = CGFloat(index % 3)
                let row = CGFloat(index / 3)
                let x = gridRect.minX + column * step
                // Draw rows from the top down.
                let y = gridRect.maxY - iconSize - row * step
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.draw(in: NSRect(x: x, y: y, width: iconSize, height: iconSize))
            }
        }

        NSGraphicsContext.current?.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: pointSize, height: pointSize))
        image.addRepresentation(rep)
        return image
    }

    /// Draws `source` into a single-bitmap thumbnail of the requested pixel size.
    nonisolated static func makeThumbnail(from source: NSImage, pointSize: CGFloat, scale: CGFloat) -> NSImage? {
        let pixel = pixelSize(pointSize: pointSize, scale: scale)
        guard pixel >= 8,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixel,
                pixelsHigh: pixel,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              ) else { return nil }

        rep.size = NSSize(width: pointSize, height: pointSize)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(
            in: NSRect(x: 0, y: 0, width: pointSize, height: pointSize),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        NSGraphicsContext.current?.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: pointSize, height: pointSize))
        image.addRepresentation(rep)
        return image
    }

    nonisolated static func pixelSize(pointSize: CGFloat, scale: CGFloat) -> Int {
        max(8, Int((pointSize * scale).rounded()))
    }

    // MARK: - Private

    private func finish(key: String, result: NSImage?, cost: Int) {
        inFlight.remove(key)
        if let result {
            cache.setObject(result, forKey: key as NSString, cost: cost)
        }
        if let callbacks = waiters.removeValue(forKey: key) {
            let image = result
            for callback in callbacks {
                if let image {
                    callback(image)
                }
            }
        }
    }
}
