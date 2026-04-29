import Foundation

enum ShowFilter: String, CaseIterable, Identifiable {
    case allStreams = "All Streams"
    case applications = "Applications"
    case virtualStreams = "Virtual Streams"

    var id: String { rawValue }
}

enum DeviceShowFilter: String, CaseIterable, Identifiable {
    case allDevices = "All Devices"
    case hardwareDevices = "Hardware Devices"
    case virtualDevices = "Virtual Devices"

    var id: String { rawValue }
}
