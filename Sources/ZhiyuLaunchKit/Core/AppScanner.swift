import AppKit
import Foundation

/// Discovers application bundles on disk.
///
/// Pure, synchronous and `nonisolated` so the whole scan can run on a background
/// queue. The catalog layer is responsible for scheduling and merging results.
enum AppScanner {
    static let ourBundleID = "com.zhiyu.launch"

    static func defaultRoots() -> [URL] {
        var roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
        ]
        let home = FileManager.default.homeDirectoryForCurrentUser
        roots.append(home.appendingPathComponent("Applications", isDirectory: true))
        return roots
    }

    /// Scan priority for de-duplication: the lower the rank, the more authoritative.
    static func rank(for url: URL) -> Int {
        let path = url.path
        if path == "/Applications" || path.hasPrefix("/Applications/Utilities") { return 0 }
        if path.hasPrefix("/System/") { return 1 }
        if path.hasPrefix("/Applications/") { return 0 }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home + "/Applications") { return 2 }
        return 3
    }

    /// Scans all roots and returns a de-duplicated, name-sorted catalog.
    static func scan(roots: [URL]) -> [AppItem] {
        var best: [String: (item: AppItem, rank: Int)] = [:]

        for root in roots {
            for url in appBundleURLs(in: root) {
                guard let item = makeItem(url: url) else { continue }
                let candidateRank = rank(for: url)
                if let existing = best[item.bundleID], existing.rank <= candidateRank { continue }
                best[item.bundleID] = (item, candidateRank)
            }
        }

        return best.values
            .map(\.item)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Enumerates `.app` bundles under `root` without descending into bundles.
    static func appBundleURLs(in root: URL, maxDepth: Int = 3) -> [URL] {
        var result: [URL] = []
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else { return [] }

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        while let entry = enumerator.nextObject() {
            guard let url = entry as? URL else { continue }
            if enumerator.level > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            if url.pathExtension == "app" {
                result.append(url)
            }
        }
        return result
    }

    /// Turns a bundle URL into an `AppItem`, applying the display filters.
    /// Returns nil for helpers, background agents and malformed bundles.
    static func makeItem(url: URL) -> AppItem? {
        guard url.pathExtension == "app", let bundle = Bundle(url: url) else { return nil }
        let info = bundle.infoDictionary

        // Skip background agents / helpers that have no real UI.
        if isTruthy(info?["LSUIElement"]) || isTruthy(info?["LSBackgroundOnly"]) { return nil }
        // Never list ourselves.
        if bundle.bundleIdentifier == ourBundleID { return nil }
        // A real app must have an entry point.
        guard bundle.executableURL != nil else { return nil }

        let bundleID = bundle.bundleIdentifier ?? "path:" + url.path
        let name = displayName(for: url, bundle: bundle)
        guard !name.isEmpty else { return nil }

        return AppItem(
            bundleID: bundleID,
            name: name,
            url: url,
            pinyinIndex: SearchMatcher.pinyinIndex(for: name)
        )
    }

    /// Localized display name, preferring Info.plist display names.
    static func displayName(for url: URL, bundle: Bundle) -> String {
        if let name = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String, !name.isEmpty {
            return name
        }
        if let name = bundle.infoDictionary?["CFBundleDisplayName"] as? String, !name.isEmpty {
            return name
        }
        if let name = bundle.localizedInfoDictionary?["CFBundleName"] as? String, !name.isEmpty {
            return name
        }
        if let name = bundle.infoDictionary?["CFBundleName"] as? String, !name.isEmpty {
            return name
        }
        let display = FileManager.default.displayName(atPath: url.path)
        return display.hasSuffix(".app") ? String(display.dropLast(4)) : display
    }

    /// Info.plist booleans can be Bool or "1"/"YES" strings.
    private static func isTruthy(_ value: Any?) -> Bool {
        switch value {
        case let bool as Bool: return bool
        case let number as NSNumber: return number.boolValue
        case let string as String: return string == "1" || string.lowercased() == "yes" || string.lowercased() == "true"
        default: return false
        }
    }
}
