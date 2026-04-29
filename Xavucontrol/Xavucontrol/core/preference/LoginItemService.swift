import Foundation
import ServiceManagement

struct LoginItemSnapshot: Hashable {
    var isEnabled: Bool
    var statusText: String
}

struct LoginItemService {
    func snapshot() -> LoginItemSnapshot {
        switch SMAppService.mainApp.status {
        case .enabled:
            return LoginItemSnapshot(
                isEnabled: true,
                statusText: "Xavucontrol will launch automatically when you log in"
            )
        case .requiresApproval:
            return LoginItemSnapshot(
                isEnabled: false,
                statusText: "Launch at login requires approval in macOS Login Items settings"
            )
        case .notRegistered:
            return LoginItemSnapshot(
                isEnabled: false,
                statusText: "Xavucontrol is not configured to launch at login"
            )
        case .notFound:
            return LoginItemSnapshot(
                isEnabled: false,
                statusText: "Launch at login is unavailable for this app bundle"
            )
        @unknown default:
            return LoginItemSnapshot(
                isEnabled: false,
                statusText: "Launch at login status is unknown"
            )
        }
    }

    func setEnabled(_ isEnabled: Bool) throws -> LoginItemSnapshot {
        if isEnabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }

        return snapshot()
    }
}
