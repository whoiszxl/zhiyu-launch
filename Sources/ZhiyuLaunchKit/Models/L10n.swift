import Foundation

/// Minimal in-code localization.
///
/// The app ships two languages (Chinese and English) and the string set is small,
/// so a table of `t(zh, en)` calls keeps things dependency-free and reviewable —
/// no resource bundles, no .strings files to keep in sync with the Makefile's
/// `.app` assembly.
enum L10n {
    static var isChinese: Bool {
        Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
    }

    /// Returns the string matching the user's preferred language.
    static func t(_ zh: String, _ en: String) -> String {
        isChinese ? zh : en
    }

    // MARK: - Shared strings

    static var search: String { t("搜索", "Search") }
    static var noMatchingApps: String { t("未找到相关应用", "No matching apps") }
    static var noAppsFound: String { t("未发现应用", "No applications found") }
    static var scanningApps: String { t("正在扫描应用…", "Scanning for apps…") }
    static var open: String { t("打开", "Open") }
    static var revealInFinder: String { t("在访达中显示", "Reveal in Finder") }
    static var moveOutOfFolder: String { t("移出文件夹", "Move Out of Folder") }
    static var rename: String { t("重命名", "Rename") }
    static var dissolveFolder: String { t("解散文件夹", "Dissolve Folder") }
    static var hideApp: String { t("隐藏此应用", "Hide App") }
    static var removeFromRecents: String { t("从「最近使用」中移除", "Remove from Recently Used") }

    // MARK: - Menu bar

    static var openLaunchpad: String { t("打开启动台", "Open Launchpad") }
    static var launchAtLogin: String { t("开机启动", "Launch at Login") }
    static var showMenuBarIcon: String { t("显示菜单栏图标", "Show Menu Bar Icon") }
    static var settingsEllipsis: String { t("设置…", "Settings…") }
    static var quitApp: String { t("退出 Zhiyu Launch", "Quit Zhiyu Launch") }

    // MARK: - Settings window

    static var settingsTitle: String { t("Zhiyu Launch 设置", "Zhiyu Launch Settings") }
    static var globalHotKey: String { t("全局快捷键", "Global Hot Key") }
    static var hotKeyHint: String {
        t("点击快捷键区域后按下新的组合键（需包含 ⌘ / ⌥ / ⌃ 至少一个修饰键）。默认 ⌥⌘L。",
          "Click the shortcut area and press a new combination (must include at least one of ⌘ / ⌥ / ⌃). Default: ⌥⌘L.")
    }
    static var recorderPrompt: String { t("请输入新组合…", "Press a new combination…") }
    static var recorderNeedModifier: String { t("需要 ⌘ / ⌥ / ⌃ 修饰键", "Needs a ⌘ / ⌥ / ⌃ modifier") }
    static var recorderUnavailable: String { t("快捷键不可用，请重试", "Shortcut unavailable, try again") }
    static var launchAtLoginError: String { t("无法设置开机启动", "Could not change launch at login") }
    static var launchAtLoginErrorDetail: String {
        t("如果正在使用 swift run 运行，请先用 make app 构建 .app 包并从包内启动。",
          "If you are running via swift run, build the .app bundle with `make app` and launch from it.")
    }
    static var showRecentApps: String { t("在启动台显示「最近使用」", "Show “Recently Used” in the launchpad") }
    static var hiddenAppsSection: String { t("已隐藏的应用", "Hidden apps") }
    static var hiddenAppsCount: String { t("当前隐藏了 %d 个应用", "%d hidden apps") }
    static var revealAllHiddenApps: String { t("全部恢复", "Restore All") }
    static var resetLayout: String { t("重置布局", "Reset Layout") }
    static var resetLayoutConfirmTitle: String { t("确定要重置启动台布局吗？", "Reset the launchpad layout?") }
    static var resetLayoutConfirmDetail: String {
        t("所有图标排序和文件夹将被清除，应用会按名称重新排列。",
          "All ordering and folders will be cleared; apps will be re-sorted by name.")
    }
    static func versionLine(_ version: String) -> String {
        t("Zhiyu Launch \(version) — 经典 Launchpad 替代品",
          "Zhiyu Launch \(version) — a classic Launchpad replacement")
    }
}
