import Foundation
import Testing
@testable import ZhiyuLaunchKit

struct AppScannerTests {
    // MARK: - Helpers

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZhiyuLaunchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func makeAppBundle(in directory: URL, name: String, info: [String: Any]) throws -> URL {
        let bundleURL = directory.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        var plist = info
        if plist["CFBundleExecutable"] == nil { plist["CFBundleExecutable"] = name }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        let executable = macOS.appendingPathComponent(plist["CFBundleExecutable"] as? String ?? name)
        FileManager.default.createFile(atPath: executable.path, contents: Data("#!/bin/sh\nexit 0\n".utf8))
        return bundleURL
    }

    // MARK: - makeItem filters

    @Test func skipsUIElementApps() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeAppBundle(in: dir, name: "Helper", info: [
            "CFBundleIdentifier": "com.example.helper",
            "LSUIElement": true,
        ])
        #expect(AppScanner.makeItem(url: url) == nil)
    }

    @Test func skipsBackgroundOnlyApps() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeAppBundle(in: dir, name: "Agent", info: [
            "CFBundleIdentifier": "com.example.agent",
            "LSBackgroundOnly": "1",
        ])
        #expect(AppScanner.makeItem(url: url) == nil)
    }

    @Test func skipsOurselves() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeAppBundle(in: dir, name: "ZhiyuLaunch", info: [
            "CFBundleIdentifier": AppScanner.ourBundleID,
        ])
        #expect(AppScanner.makeItem(url: url) == nil)
    }

    @Test func keepsNormalAppsWithLocalizedName() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeAppBundle(in: dir, name: "Example", info: [
            "CFBundleIdentifier": "com.example.app",
            "CFBundleName": "Example",
            "CFBundleDisplayName": "示例应用",
        ])
        let item = try #require(AppScanner.makeItem(url: url))
        #expect(item.bundleID == "com.example.app")
        #expect(item.name == "示例应用")
    }

    @Test func nameFallsBackToFileSystemDisplayName() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeAppBundle(in: dir, name: "PlainApp", info: [
            "CFBundleIdentifier": "com.example.plain",
        ])
        let item = try #require(AppScanner.makeItem(url: url))
        #expect(item.name == "PlainApp")
    }

    @Test func syntheticBundleIDForAppsWithoutIdentifier() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try makeAppBundle(in: dir, name: "NoID", info: [:])
        let item = try #require(AppScanner.makeItem(url: url))
        #expect(item.bundleID.hasPrefix("path:"))
    }

    // MARK: - Scanning

    @Test func scanDeduplicatesByBundleIdentifier() throws {
        let rootA = try makeTempDirectory()
        let rootB = try makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }
        let firstURL = try makeAppBundle(in: rootA, name: "Dupe", info: ["CFBundleIdentifier": "com.example.dupe"])
        try makeAppBundle(in: rootB, name: "DupeCopy", info: ["CFBundleIdentifier": "com.example.dupe"])

        let apps = AppScanner.scan(roots: [rootA, rootB])
        #expect(apps.count == 1)
        // Both roots have the same (unknown-path) rank, so the first root wins.
        // Note: URL comparison must resolve /var → /private/var.
        #expect(apps[0].url.resolvingSymlinksInPath() == firstURL.resolvingSymlinksInPath())
    }

    @Test func scanDoesNotDescendIntoAppBundles() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outer = try makeAppBundle(in: root, name: "Outer", info: ["CFBundleIdentifier": "com.example.outer"])
        // Simulate a nested helper app inside the outer bundle.
        let helpers = outer.appendingPathComponent("Contents/Helpers", isDirectory: true)
        try makeAppBundle(in: helpers, name: "Inner", info: ["CFBundleIdentifier": "com.example.inner"])

        let urls = AppScanner.appBundleURLs(in: root)
        #expect(urls.count == 1)
        #expect(urls[0].lastPathComponent == "Outer.app")
    }

    @Test func scanResultsAreNameSorted() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeAppBundle(in: root, name: "Zeta", info: ["CFBundleIdentifier": "com.example.z", "CFBundleName": "Zeta"])
        try makeAppBundle(in: root, name: "Alpha", info: ["CFBundleIdentifier": "com.example.a", "CFBundleName": "Alpha"])
        let apps = AppScanner.scan(roots: [root])
        #expect(apps.map(\.name) == ["Alpha", "Zeta"])
    }

    // MARK: - Ranking

    @Test func applicationFolderRanksFirst() {
        #expect(AppScanner.rank(for: URL(fileURLWithPath: "/Applications/Safari.app")) == 0)
        #expect(AppScanner.rank(for: URL(fileURLWithPath: "/Applications/Utilities/Terminal.app")) == 0)
        #expect(AppScanner.rank(for: URL(fileURLWithPath: "/System/Applications/Mail.app")) == 1)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(AppScanner.rank(for: URL(fileURLWithPath: "\(home)/Applications/Mine.app")) == 2)
        #expect(AppScanner.rank(for: URL(fileURLWithPath: "/opt/custom/Thing.app")) == 3)
    }

    // MARK: - Environment smoke test

    @Test func findsSystemUtilitiesOnThisMachine() throws {
        let root = URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else {
            return // No such directory on this machine; nothing to smoke-test.
        }
        let apps = AppScanner.scan(roots: [root])
        #expect(apps.count >= 3, "Expected to find system utilities, got \(apps.count)")
        #expect(apps.allSatisfy { $0.bundleID != AppScanner.ourBundleID })
    }
}
