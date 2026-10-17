import Foundation

/// Remembers which applications the user has hidden from the launchpad.
///
/// Hiding only affects display: the layout keeps the app's position, so unhiding
/// restores it exactly where it was.
@MainActor
final class HiddenAppsStore {
    private let defaults: UserDefaults
    private let key = "hiddenAppBundleIDs"

    private(set) var bundleIDs: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.bundleIDs = Set(defaults.stringArray(forKey: key) ?? [])
    }

    func contains(_ bundleID: String) -> Bool {
        bundleIDs.contains(bundleID)
    }

    func hide(_ bundleID: String) {
        guard !bundleID.isEmpty, !bundleIDs.contains(bundleID) else { return }
        bundleIDs.insert(bundleID)
        persist()
    }

    func unhide(_ bundleID: String) {
        guard bundleIDs.remove(bundleID) != nil else { return }
        persist()
    }

    func unhideAll() {
        guard !bundleIDs.isEmpty else { return }
        bundleIDs.removeAll()
        persist()
    }

    private func persist() {
        defaults.set(bundleIDs.sorted(), forKey: key)
    }
}
