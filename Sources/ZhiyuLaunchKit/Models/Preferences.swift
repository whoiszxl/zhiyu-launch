import Carbon.HIToolbox
import Foundation

/// A global hot key combination expressed with Carbon key codes / modifiers.
struct HotKeyCombo: Codable, Sendable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    static let `default` = HotKeyCombo(
        keyCode: UInt32(kVK_ANSI_L),
        carbonModifiers: UInt32(cmdKey | optionKey)
    )

    /// Human readable form, e.g. "⌥⌘L".
    var displayString: String {
        var result = ""
        if carbonModifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        result += KeyCodeNames.name(for: keyCode)
        return result
    }
}

/// Maps Carbon virtual key codes to display names for the shortcut recorder.
enum KeyCodeNames {
    static func name(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Grave: return "`"
        case kVK_Space: return "空格"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default: return "Key\(keyCode)"
        }
    }
}

/// User defaults backed preferences.
@MainActor
final class Preferences {
    static let shared = Preferences()

    private let defaults: UserDefaults

    private enum Key {
        static let hotKey = "hotKeyCombo"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let showRecentApps = "showRecentApps"
        static let hasLaunchedBefore = "hasLaunchedBefore"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var hotKey: HotKeyCombo {
        get {
            guard let data = defaults.data(forKey: Key.hotKey),
                  let combo = try? JSONDecoder().decode(HotKeyCombo.self, from: data) else {
                return .default
            }
            return combo
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.hotKey)
            }
        }
    }

    /// Whether the menu bar status item is shown.
    var showMenuBarIcon: Bool {
        get { defaults.object(forKey: Key.showMenuBarIcon) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.showMenuBarIcon) }
    }

    /// Whether the "recently used" strip is shown in the launchpad.
    var showRecentApps: Bool {
        get { defaults.object(forKey: Key.showRecentApps) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.showRecentApps) }
    }

    /// Used to open the panel once on the very first launch so users see something happen.
    var hasLaunchedBefore: Bool {
        get { defaults.bool(forKey: Key.hasLaunchedBefore) }
        set { defaults.set(newValue, forKey: Key.hasLaunchedBefore) }
    }
}
