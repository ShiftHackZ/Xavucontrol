import Foundation

actor RoutingRouterService {
    static let shared = RoutingRouterService()

    private var routes: [String: RouterRoute] = [:]
    private var streamControls: [String: RouterStreamControl] = [:]

    func handle(_ message: RoutingIPCMessage) -> RouterCommandResult {
        switch message {
        case .setRoute(let routeMessage):
            return setRoute(routeMessage)
        case .removeRoute(let removeMessage):
            return removeRoute(removeMessage)
        case .setStreamVolume(let volumeMessage):
            return setStreamVolume(volumeMessage)
        case .setStreamMuted(let mutedMessage):
            return setStreamMuted(mutedMessage)
        }
    }

    func snapshot() -> RouterStateSnapshot {
        RouterStateSnapshot(
            routes: routes.values.sorted { $0.streamID < $1.streamID },
            streamControls: streamControls.values.sorted { $0.streamID < $1.streamID }
        )
    }

    private func setRoute(_ message: SetRouteMessage) -> RouterCommandResult {
        let route = RouterRoute(
            streamID: message.streamID,
            processID: message.processID,
            direction: message.direction,
            targetDeviceID: message.targetDeviceID,
            targetCoreAudioObjectID: message.targetCoreAudioObjectID,
            updatedAt: Date()
        )
        routes[message.streamID] = route
        return .accepted("Router route table updated for \(message.streamID)")
    }

    private func removeRoute(_ message: RemoveRouteMessage) -> RouterCommandResult {
        routes.removeValue(forKey: message.streamID)
        return .accepted("Router route removed for \(message.streamID)")
    }

    private func setStreamVolume(_ message: SetStreamVolumeMessage) -> RouterCommandResult {
        var control = streamControls[message.streamID] ?? RouterStreamControl(streamID: message.streamID)
        control.volume = message.volume
        control.updatedAt = Date()
        streamControls[message.streamID] = control
        return .accepted("Router stream volume updated for \(message.streamID)")
    }

    private func setStreamMuted(_ message: SetStreamMutedMessage) -> RouterCommandResult {
        var control = streamControls[message.streamID] ?? RouterStreamControl(streamID: message.streamID)
        control.isMuted = message.isMuted
        control.updatedAt = Date()
        streamControls[message.streamID] = control
        return .accepted("Router stream mute updated for \(message.streamID)")
    }
}

struct RouterRoute: Codable, Hashable, Identifiable {
    var id: String { streamID }
    var streamID: String
    var processID: Int32?
    var direction: String
    var targetDeviceID: String
    var targetCoreAudioObjectID: UInt32?
    var updatedAt: Date
}

struct RouterStreamControl: Codable, Hashable, Identifiable {
    var id: String { streamID }
    var streamID: String
    var volume: Double?
    var isMuted: Bool?
    var updatedAt: Date

    nonisolated init(streamID: String, volume: Double? = nil, isMuted: Bool? = nil, updatedAt: Date = Date()) {
        self.streamID = streamID
        self.volume = volume
        self.isMuted = isMuted
        self.updatedAt = updatedAt
    }
}

struct RouterStateSnapshot: Codable, Hashable {
    var routes: [RouterRoute]
    var streamControls: [RouterStreamControl]
}

enum RouterCommandResult: Hashable {
    case accepted(String)
    case rejected(String)

    var displayText: String {
        switch self {
        case .accepted(let message):
            return message
        case .rejected(let message):
            return message
        }
    }
}
