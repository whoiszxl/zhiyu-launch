import Foundation
import ServiceManagement

/// Launch-at-login support through `SMAppService` (macOS 13+, no helper bundle).
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Toggles registration. Throws when the app is not running from a proper
    /// `.app` bundle (e.g. `swift run` during development).
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
