import Foundation

enum SetupDiagnosticState: Hashable {
    case ready
    case warning
    case missing
    case blocked

    var iconName: String {
        switch self {
        case .ready:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .missing:
            return "xmark.circle.fill"
        case .blocked:
            return "lock.fill"
        }
    }
}

struct SetupDiagnosticItem: Identifiable, Hashable {
    let id: String
    var title: String
    var detail: String
    var state: SetupDiagnosticState
}

struct SetupState: Hashable {
    nonisolated static let virtualCableName = "Xavucontrol Virtual Cable"
    nonisolated static let virtualMicName = "Xavucontrol Virtual Mic"

    var virtualCableOutputID: AudioDevice.ID?
    var virtualCableInputID: AudioDevice.ID?
    var isVirtualOutputDefault: Bool
    var isVirtualInputDefault: Bool
    var installStatus: String
    var defaultDeviceStatus: String
    var bundledDriverStatus: String
    var microphoneAccessStatus: String
    var isInstalling: Bool
    var diagnostics: [SetupDiagnosticItem]

    static var initial: SetupState {
        SetupState(
            virtualCableOutputID: nil,
            virtualCableInputID: nil,
            isVirtualOutputDefault: false,
            isVirtualInputDefault: false,
            installStatus: "Virtual cable not installed",
            defaultDeviceStatus: "Virtual cable is not selected as a system default device",
            bundledDriverStatus: "Bundled driver not checked yet",
            microphoneAccessStatus: "Microphone access not checked yet",
            isInstalling: false,
            diagnostics: []
        )
    }
}
