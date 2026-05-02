import Foundation

enum RoutingBackendKind: String {
    case directCoreAudio = "Direct Core Audio"
    case virtualDevice = "Virtual Device"
}

enum RoutingBackendResult: Hashable {
    case applied(String)
    case queued(String)
    case unsupported(String)
    case failed(String)
}

protocol RoutingBackend {
    var kind: RoutingBackendKind { get }
    var statusText: String { get }

    func apply(
        routeRequest: AudioRouteRequest,
        stream: AppAudioStream,
        targetDevice: AudioDevice
    ) async -> RoutingBackendResult

    func apply(
        routeRequests: [AudioRouteRequest],
        stream: AppAudioStream,
        targetDevices: [AudioDevice]
    ) async -> RoutingBackendResult

    func setStreamVolume(stream: AppAudioStream, volume: Double) async -> RoutingBackendResult

    func setStreamMuted(stream: AppAudioStream, isMuted: Bool) async -> RoutingBackendResult
}

extension RoutingBackend {
    func apply(
        routeRequests: [AudioRouteRequest],
        stream: AppAudioStream,
        targetDevices: [AudioDevice]
    ) async -> RoutingBackendResult {
        guard let routeRequest = routeRequests.first,
              let targetDevice = targetDevices.first else {
            return .failed("No output devices selected")
        }
        return await apply(routeRequest: routeRequest, stream: stream, targetDevice: targetDevice)
    }
}

struct RoutingEngine {
    private let backend: RoutingBackend

    init(backend: RoutingBackend) {
        self.backend = backend
    }

    var backendStatus: String {
        backend.statusText
    }

    func apply(
        routeRequest: AudioRouteRequest,
        stream: AppAudioStream,
        targetDevice: AudioDevice
    ) async -> RoutingBackendResult {
        await backend.apply(routeRequest: routeRequest, stream: stream, targetDevice: targetDevice)
    }

    func apply(
        routeRequests: [AudioRouteRequest],
        stream: AppAudioStream,
        targetDevices: [AudioDevice]
    ) async -> RoutingBackendResult {
        await backend.apply(routeRequests: routeRequests, stream: stream, targetDevices: targetDevices)
    }

    func setStreamVolume(stream: AppAudioStream, volume: Double) async -> RoutingBackendResult {
        await backend.setStreamVolume(stream: stream, volume: volume)
    }

    func setStreamMuted(stream: AppAudioStream, isMuted: Bool) async -> RoutingBackendResult {
        await backend.setStreamMuted(stream: stream, isMuted: isMuted)
    }
}

extension RoutingStatus {
    init(result: RoutingBackendResult) {
        switch result {
        case .applied(let detail):
            self = .active(detail)
        case .queued(let detail):
            self = .queued(detail)
        case .unsupported(let reason):
            self = .unsupported(reason)
        case .failed(let reason):
            self = .failed(reason)
        }
    }
}

struct DirectCoreAudioRoutingBackend: RoutingBackend {
    let kind: RoutingBackendKind = .directCoreAudio

    var statusText: String {
        "Direct Core Audio routing cannot move another process stream to a different device"
    }

    func apply(
        routeRequest: AudioRouteRequest,
        stream: AppAudioStream,
        targetDevice: AudioDevice
    ) async -> RoutingBackendResult {
        .unsupported(
            "Direct Core Audio exposes process/device state, but not PulseAudio-style per-app stream routing. Route request saved for future virtual-device backend."
        )
    }

    func apply(
        routeRequests: [AudioRouteRequest],
        stream: AppAudioStream,
        targetDevices: [AudioDevice]
    ) async -> RoutingBackendResult {
        guard let routeRequest = routeRequests.first,
              let targetDevice = targetDevices.first else {
            return .failed("No output devices selected")
        }
        return await apply(routeRequest: routeRequest, stream: stream, targetDevice: targetDevice)
    }

    func setStreamVolume(stream: AppAudioStream, volume: Double) async -> RoutingBackendResult {
        .unsupported("Direct Core Audio cannot set another process stream volume")
    }

    func setStreamMuted(stream: AppAudioStream, isMuted: Bool) async -> RoutingBackendResult {
        .unsupported("Direct Core Audio cannot set another process stream mute")
    }
}
