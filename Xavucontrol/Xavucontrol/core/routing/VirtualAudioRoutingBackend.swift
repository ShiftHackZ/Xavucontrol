import Foundation

enum VirtualAudioDriverState: Hashable {
    case notInstalled
    case installed
    case running
    case unavailable(String)

    var displayText: String {
        switch self {
        case .notInstalled:
            return "Virtual audio driver is not installed"
        case .installed:
            return "Virtual audio driver is installed but not connected"
        case .running:
            return "Virtual audio driver is running"
        case .unavailable(let reason):
            return reason
        }
    }
}

struct VirtualAudioRoutingBackend: RoutingBackend {
    let kind: RoutingBackendKind = .virtualDevice
    var driverState: VirtualAudioDriverState = .notInstalled
    var transport: RoutingIPCTransport = RoutingCommandQueueTransport()

    var statusText: String {
        "Virtual cable per-app routing backend is ready; waiting for Core Audio device scan"
    }

    func apply(
        routeRequest: AudioRouteRequest,
        stream: AppAudioStream,
        targetDevice: AudioDevice
    ) async -> RoutingBackendResult {
        await apply(routeRequests: [routeRequest], stream: stream, targetDevices: [targetDevice])
    }

    func apply(
        routeRequests: [AudioRouteRequest],
        stream: AppAudioStream,
        targetDevices: [AudioDevice]
    ) async -> RoutingBackendResult {
        guard !stream.isVirtualStream else {
            return .unsupported("Virtual streams are diagnostic Xavucontrol outputs and cannot be routed by the POC backend")
        }

        if stream.direction == .playback {
            guard !targetDevices.isEmpty else {
                return .failed("No output devices selected")
            }

            do {
                await VirtualCableRoutingService.shared.stop(streamID: stream.id)
                let summary = try await ProcessTapRoutingService.shared.routeConfirmed(stream: stream, to: targetDevices)
                return .applied(summary)
            } catch {
                let virtualProbeSourceUID = ProcessTapRoutingService.sourceDeviceUID(
                    processObjectID: ProcessTapRoutingService.processObjectID(from: stream.id),
                    assignedDeviceID: stream.assignedDeviceID
                )
                let hardwareProbeSourceUID = ProcessTapRoutingService.diagnosticHardwareSourceDeviceUID(
                    processObjectID: ProcessTapRoutingService.processObjectID(from: stream.id),
                    assignedDeviceID: stream.assignedDeviceID
                )
                let virtualProbeSummary = await ProcessTapRoutingService.shared.probeGlobalTap(sourceDeviceUID: virtualProbeSourceUID)
                let hardwareProbeSummary = await ProcessTapRoutingService.shared.probeGlobalTap(sourceDeviceUID: hardwareProbeSourceUID)
                let probeSummary = "\(virtualProbeSummary). Hardware probe: \(hardwareProbeSummary)"
                if await ProcessTapRoutingService.shared.hasActiveRoutes() {
                    return .failed("Per-app process tap failed for \(stream.appName): \(error.localizedDescription). \(probeSummary). Mixed fallback was not started because another per-app route is active.")
                }

                do {
                    guard let targetDevice = targetDevices.first else {
                        return .failed("No output devices selected")
                    }
                    let fallbackSummary = try await VirtualCableRoutingService.shared.route(stream: stream, to: targetDevice)
                    return .applied("\(fallbackSummary) Per-app process tap is not ready yet: \(error.localizedDescription). \(probeSummary)")
                } catch {
                    return .failed("Per-app tap and virtual cable fallback failed: \(error.localizedDescription). \(probeSummary)")
                }
            }
        }

        let message = RoutingIPCMessage.setRoute(SetRouteMessage(
            streamID: routeRequests.first?.streamID ?? stream.id,
            processID: stream.processID,
            direction: routeRequests.first?.direction.rawValue ?? stream.direction.rawValue,
            targetDeviceID: targetDevices.first?.id ?? "",
            targetCoreAudioObjectID: targetDevices.first?.coreAudioObjectID
        ))

        do {
            let receipt = try await transport.send(message)
            switch driverState {
            case .running:
                return .queued("Route command sent to virtual backend: \(receipt.routerSummary)")
            case .notInstalled, .installed, .unavailable:
                return .queued("\(receipt.routerSummary). \(driverState.displayText).")
            }
        } catch {
            return .failed("Failed to send route command: \(error.localizedDescription)")
        }
    }

    func setStreamVolume(stream: AppAudioStream, volume: Double) async -> RoutingBackendResult {
        if stream.direction == .playback,
           await ProcessTapRoutingService.shared.setStreamVolume(streamID: stream.id, volume: volume) {
            return .applied("Stream volume updated for \(stream.appName)")
        }

        return await sendControlMessage(.setStreamVolume(SetStreamVolumeMessage(
            streamID: stream.id,
            volume: volume
        )))
    }

    func setStreamMuted(stream: AppAudioStream, isMuted: Bool) async -> RoutingBackendResult {
        if stream.direction == .playback,
           await ProcessTapRoutingService.shared.setStreamMuted(streamID: stream.id, isMuted: isMuted) {
            return .applied(isMuted ? "Stream muted for \(stream.appName)" : "Stream unmuted for \(stream.appName)")
        }

        return await sendControlMessage(.setStreamMuted(SetStreamMutedMessage(
            streamID: stream.id,
            isMuted: isMuted
        )))
    }

    private func sendControlMessage(_ message: RoutingIPCMessage) async -> RoutingBackendResult {
        do {
            let receipt = try await transport.send(message)
            switch driverState {
            case .running:
                return .queued("Control command sent to virtual backend: \(receipt.routerSummary)")
            case .notInstalled, .installed, .unavailable:
                return .queued("\(receipt.routerSummary). \(driverState.displayText).")
            }
        } catch {
            return .failed("Failed to send control command: \(error.localizedDescription)")
        }
    }
}

enum RoutingIPCMessage: Codable, Hashable {
    case setRoute(SetRouteMessage)
    case removeRoute(RemoveRouteMessage)
    case setStreamVolume(SetStreamVolumeMessage)
    case setStreamMuted(SetStreamMutedMessage)
}

struct SetRouteMessage: Codable, Hashable {
    var streamID: String
    var processID: Int32?
    var direction: String
    var targetDeviceID: String
    var targetCoreAudioObjectID: UInt32?
}

struct RemoveRouteMessage: Codable, Hashable {
    var streamID: String
}

struct SetStreamVolumeMessage: Codable, Hashable {
    var streamID: String
    var volume: Double
}

struct SetStreamMutedMessage: Codable, Hashable {
    var streamID: String
    var isMuted: Bool
}
