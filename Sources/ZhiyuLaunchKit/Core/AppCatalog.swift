import AppKit
import Foundation

/// Watches a directory with kqueue-backed dispatch sources (no polling).
final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject
    private let fd: Int32

    init?(path: String, queue: DispatchQueue = .main, handler: @escaping @Sendable () -> Void) {
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        fd = descriptor
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .attrib, .extend],
            queue: queue
        )
        source.setEventHandler(handler: handler)
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    deinit {
        source.cancel()
    }
}

/// Owns the discovered application catalog.
///
/// - Performs the initial scan asynchronously (never on the main thread).
/// - Supplements directory scans with Spotlight results so apps outside the
///   standard folders still show up.
/// - Refreshes on file-system events and volume mounts, debounced; there is no
///   timer polling anywhere.
@MainActor
final class AppCatalog {
    private(set) var apps: [AppItem] = []
    /// True once at least one full directory scan has completed. The layout must
    /// not be reconciled against a partial catalog (Spotlight results can arrive
    /// before the directory scan), otherwise missing entries would be dropped
    /// and the user's layout persisted in a degraded state.
    private(set) var hasCompletedDirectoryScan = false
    /// Called on the main actor whenever `apps` changes.
    var onChange: (([AppItem]) -> Void)?

    private var directoryWatchers: [DirectoryWatcher] = []
    private var spotlightApps: [String: AppItem] = [:]
    private var scannedApps: [AppItem] = []
    private var pendingRescan: DispatchWorkItem?
    private var isScanning = false
    private var started = false
    private var metadataQuery: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard !started else { return }
        started = true
        startWatchingDirectories()
        startSpotlightSupplement()

        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.rescanSoon() }
            }
            observers.append(token)
        }

        rescan()
    }

    /// Debounced refresh; safe to call from file-system events.
    func rescanSoon(delay: TimeInterval = 3) {
        pendingRescan?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.rescan() }
        pendingRescan = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func rescan() {
        guard !isScanning else { return }
        isScanning = true
        let roots = AppScanner.defaultRoots()
        Task.detached(priority: .utility) { [weak self] in
            let scanned = AppScanner.scan(roots: roots)
            await self?.finishDirectoryScan(scanned)
        }
    }

    private func finishDirectoryScan(_ scanned: [AppItem]) {
        isScanning = false
        scannedApps = scanned
        hasCompletedDirectoryScan = true
        publish()
    }

    private func publish() {
        var byID = Dictionary(uniqueKeysWithValues: scannedApps.map { ($0.bundleID, $0) })
        for (bundleID, item) in spotlightApps where byID[bundleID] == nil {
            byID[bundleID] = item
        }
        let merged = byID.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        AppLog.debug("catalog publish: scanned=\(scannedApps.count) spotlight=\(spotlightApps.count) merged=\(merged.count) complete=\(hasCompletedDirectoryScan)")
        guard merged != apps else { return }
        apps = merged
        onChange?(merged)
    }

    // MARK: - Directory watching

    private func startWatchingDirectories() {
        let paths = [
            "/Applications",
            "/Applications/Utilities",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path,
        ]
        for path in paths {
            guard let watcher = DirectoryWatcher(path: path, handler: { [weak self] in
                Task { @MainActor [weak self] in self?.rescanSoon() }
            }) else { continue }
            directoryWatchers.append(watcher)
        }
    }

    // MARK: - Spotlight supplement

    private func startSpotlightSupplement() {
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "kMDItemContentTypeTree == %@", "com.apple.application-bundle")
        query.searchScopes = [NSMetadataQueryLocalComputerScope]
        let token = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The closure runs on the main queue; only one query is ever active.
            MainActor.assumeIsolated {
                guard let self, let query = self.metadataQuery else { return }
                self.finishSpotlightQuery(query)
            }
        }
        observers.append(token)
        metadataQuery = query
        query.start()
    }

    private func finishSpotlightQuery(_ query: NSMetadataQuery) {
        query.disableUpdates()
        var extras: [String: AppItem] = [:]
        if let results = query.results as? [NSMetadataItem] {
            for result in results {
                guard let path = result.value(forAttribute: kMDItemPath as String) as? String else { continue }
                // Only top-level bundles: "Foo.app/Contents/..." is a nested helper.
                if path.contains(".app/") { continue }
                guard let item = AppScanner.makeItem(url: URL(fileURLWithPath: path)) else { continue }
                extras[item.bundleID] = item
            }
        }
        query.stop()
        metadataQuery = nil
        spotlightApps = extras
        publish()
    }
}
