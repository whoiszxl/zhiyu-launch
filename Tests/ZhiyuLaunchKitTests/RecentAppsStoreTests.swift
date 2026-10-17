import Foundation
import Testing
@testable import ZhiyuLaunchKit

@MainActor
struct RecentAppsStoreTests {
    private func makeStore(maxCount: Int = 10) -> (RecentAppsStore, UserDefaults, String) {
        let suite = "com.zhiyu.launch.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (RecentAppsStore(defaults: defaults, maxCount: maxCount), defaults, suite)
    }

    @Test func recordsMostRecentFirstAndDeduplicates() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        store.record("a")
        store.record("b")
        store.record("a")
        #expect(store.bundleIDs == ["a", "b"])
    }

    @Test func capsAtMaxCount() {
        let (store, defaults, suite) = makeStore(maxCount: 3)
        defer { defaults.removePersistentDomain(forName: suite) }

        for id in ["a", "b", "c", "d"] { store.record(id) }
        #expect(store.bundleIDs == ["d", "c", "b"])
    }

    @Test func skipsEmptyIdentifiers() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        store.record("")
        #expect(store.bundleIDs.isEmpty)
    }

    @Test func persistsAcrossInstances() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        store.record("com.example.app")
        let reloaded = RecentAppsStore(defaults: defaults)
        #expect(reloaded.bundleIDs == ["com.example.app"])
    }

    @Test func removeAndClear() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        store.record("a")
        store.record("b")
        store.remove("a")
        #expect(store.bundleIDs == ["b"])
        store.clear()
        #expect(store.bundleIDs.isEmpty)
    }

    @Test func mapsOnlyInstalledAppsInRecencyOrder() {
        let (store, defaults, suite) = makeStore()
        defer { defaults.removePersistentDomain(forName: suite) }

        store.record("gone")
        store.record("second")
        store.record("first")

        let catalog = [
            AppItem(bundleID: "first", name: "First", url: URL(fileURLWithPath: "/Applications/First.app")),
            AppItem(bundleID: "second", name: "Second", url: URL(fileURLWithPath: "/Applications/Second.app")),
        ]
        let mapped = store.recentApps(from: catalog)
        #expect(mapped.map(\.bundleID) == ["first", "second"])
    }
}
