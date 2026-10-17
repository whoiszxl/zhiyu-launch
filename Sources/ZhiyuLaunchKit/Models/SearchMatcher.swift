import Foundation

/// Name matching for the search field. Kept standalone so the behavior is
/// unit-testable without any UI.
enum SearchMatcher {
    /// Case-insensitive, localized substring match.
    static func matches(name: String, query: String) -> Bool {
        matches(name: name, pinyin: "", query: query)
    }

    /// Matches the display name directly, or the pinyin index for Chinese names
    /// (full pinyin "weixin" or initials "wx").
    static func matches(name: String, pinyin: String, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        if name.localizedCaseInsensitiveContains(trimmed) {
            return true
        }
        guard !pinyin.isEmpty else { return false }
        return pinyin.contains(trimmed.lowercased())
    }

    /// Builds the pinyin search index for a display name.
    ///
    /// Uses the system's built-in transliteration (`CFStringTransform`), so no
    /// third-party pinyin tables are needed. Latin-only names return an empty
    /// index (the name itself already matches).
    static func pinyinIndex(for name: String) -> String {
        guard name.unicodeScalars.contains(where: { $0.value > 0x7F }) else { return "" }

        let mutable = NSMutableString(string: name) as CFMutableString
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)

        let latin = (mutable as String).lowercased()
        let tokens = latin.split { !$0.isLetter && !$0.isNumber }
        let full = tokens.joined()
        guard !full.isEmpty else { return "" }
        let initials = tokens.compactMap { $0.first.map(String.init) }.joined()
        return "\(full)|\(initials)"
    }
}
