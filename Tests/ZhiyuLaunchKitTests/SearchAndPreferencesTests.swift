import Foundation
import Testing
@testable import ZhiyuLaunchKit

struct SearchMatcherTests {
    @Test func emptyQueryMatchesEverything() {
        #expect(SearchMatcher.matches(name: "Safari", query: ""))
        #expect(SearchMatcher.matches(name: "Safari", query: "   "))
    }

    @Test func caseInsensitiveEnglish() {
        #expect(SearchMatcher.matches(name: "Safari", query: "saf"))
        #expect(SearchMatcher.matches(name: "Safari", query: "SAFARI"))
        #expect(!SearchMatcher.matches(name: "Safari", query: "chrome"))
    }

    @Test func chineseSubstring() {
        #expect(SearchMatcher.matches(name: "微信", query: "微"))
        #expect(SearchMatcher.matches(name: "腾讯会议", query: "会议"))
        #expect(!SearchMatcher.matches(name: "微信", query: "钉钉"))
    }

    @Test func queryIsTrimmed() {
        #expect(SearchMatcher.matches(name: "Xcode", query: "  code  "))
    }

    @Test func pinyinInitialsMatchChineseNames() {
        let pinyin = SearchMatcher.pinyinIndex(for: "微信")
        #expect(!pinyin.isEmpty)
        #expect(SearchMatcher.matches(name: "微信", pinyin: pinyin, query: "wx"))
        #expect(SearchMatcher.matches(name: "微信", pinyin: pinyin, query: "weixin"))
        #expect(SearchMatcher.matches(name: "微信", pinyin: pinyin, query: "wei"))
        #expect(!SearchMatcher.matches(name: "微信", pinyin: pinyin, query: "qq"))
    }

    @Test func pinyinIndexSupportsMixedNames() {
        let pinyin = SearchMatcher.pinyinIndex(for: "腾讯会议")
        #expect(SearchMatcher.matches(name: "腾讯会议", pinyin: pinyin, query: "txhy"))
        #expect(SearchMatcher.matches(name: "腾讯会议", pinyin: pinyin, query: "tengxun"))
    }

    @Test func pinyinIndexIsEmptyForLatinNames() {
        #expect(SearchMatcher.pinyinIndex(for: "Safari").isEmpty)
        #expect(SearchMatcher.pinyinIndex(for: "Xcode 27").isEmpty)
    }

    @Test func pinyinMatchingIsCaseInsensitive() {
        let pinyin = SearchMatcher.pinyinIndex(for: "微信")
        #expect(SearchMatcher.matches(name: "微信", pinyin: pinyin, query: "WX"))
    }
}

struct HotKeyComboTests {
    @Test func displayStringOrdersModifiers() {
        let combo = HotKeyCombo(keyCode: 37, carbonModifiers: 256 | 2048) // cmd + option + L
        #expect(combo.displayString == "⌥⌘L")
    }

    @Test func fullModifierCombination() {
        let combo = HotKeyCombo(keyCode: 49, carbonModifiers: 256 | 512 | 2048 | 4096) // cmd+shift+option+control+space
        #expect(combo.displayString == "⌃⌥⇧⌘空格")
    }

    @Test func codableRoundTrip() throws {
        let combo = HotKeyCombo(keyCode: 12, carbonModifiers: 256)
        let data = try JSONEncoder().encode(combo)
        #expect(try JSONDecoder().decode(HotKeyCombo.self, from: data) == combo)
    }
}

struct LayoutStoreTests {
    @Test func saveAndLoadRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zhiyu-layout-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = LayoutStore(fileURL: url)
        let folder = LayoutFolder(name: "F", appIDs: ["x", "y"])
        let model = LayoutModel(items: [.app("a"), .folder(folder)])
        store.save(model)

        let loaded = store.load()
        #expect(loaded == model)
    }

    @Test func loadReturnsEmptyModelForMissingFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zhiyu-missing-\(UUID().uuidString).json")
        let store = LayoutStore(fileURL: url)
        #expect(store.load().items.isEmpty)
    }

    @Test func loadBacksUpCorruptFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zhiyu-corrupt-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("bak"))
        }
        try Data("not json".utf8).write(to: url)

        let store = LayoutStore(fileURL: url)
        #expect(store.load().items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path))
    }
}
