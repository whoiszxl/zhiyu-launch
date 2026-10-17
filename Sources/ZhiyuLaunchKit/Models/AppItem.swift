import Foundation

/// A launchable application discovered on disk.
///
/// `bundleID` is the stable identity used by the layout model and the icon cache.
/// Apps without a real bundle identifier get a synthetic `path:` identifier so
/// they still show up in the grid.
struct AppItem: Sendable, Hashable, Identifiable {
    let bundleID: String
    let name: String
    let url: URL
    /// Lowercased pinyin index for Chinese names ("weixin|wx" style), empty for
    /// names that are already Latin. Built once during the background scan.
    let pinyinIndex: String

    var id: String { bundleID }

    init(bundleID: String, name: String, url: URL, pinyinIndex: String = "") {
        self.bundleID = bundleID
        self.name = name
        self.url = url
        self.pinyinIndex = pinyinIndex
    }
}
