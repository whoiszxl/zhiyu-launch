import AppKit
import Foundation

/// Remembers recently used applications (by bundle identifier) so the launchpad
/// can offer a "recently used" strip.
///
/// Records come from `NSWorkspace.didActivateApplicationNotification`, so the list
/// covers apps launched from anywhere in the system, not just this launcher.
/// Persistence is a plain `UserDefaults` string array — tiny and dependency-free.
@MainActor
final class RecentAppsStore {
    private let defaults: UserDefaults
    private let key = "recentAppBundleIDs"
    let maxCount: Int

    private(set) var bundleIDs: [String]

    init(defaults: UserDefaults = .standard, maxCount: Int = 10) {
        self.defaults = defaults
        self.maxCount = maxCount
        self.bundleIDs = defaults.stringArray(forKey: key) ?? []
    }

    /// Moves the bundle identifier to the front (deduplicated, capped).
    func record(_ bundleID: String) {
        guard !bundleID.isEmpty, bundleID != Bundle.main.bundleIdentifier else { return }
        var updated = bundleIDs.filter { $0 != bundleID }
        updated.insert(bundleID, at: 0)
        if updated.count > maxCount {
            updated = Array(updated.prefix(maxCount))
        }
        guard updated != bundleIDs else { return }
        bundleIDs = updated
        defaults.set(updated, forKey: key)
    }

    func remove(_ bundleID: String) {
        let updated = bundleIDs.filter { $0 != bundleID }
        guard updated != bundleIDs else { return }
        bundleIDs = updated
        defaults.set(updated, forKey: key)
    }

    func clear() {
        guard !bundleIDs.isEmpty else { return }
        bundleIDs = []
        defaults.removeObject(forKey: key)
    }

    /// Maps the recorded identifiers to installed apps, preserving recency order.
    func recentApps(from catalog: [AppItem]) -> [AppItem] {
        guard !bundleIDs.isEmpty else { return [] }
        var byID: [String: AppItem] = [:]
        for app in catalog { byID[app.bundleID] = app }
        return bundleIDs.compactMap { byID[$0] }
    }
}
