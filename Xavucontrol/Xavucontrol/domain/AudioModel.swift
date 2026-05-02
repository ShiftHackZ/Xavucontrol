import Foundation
import Combine
import CoreAudio

enum StreamDirection: String, CaseIterable, Identifiable {
    case playback = "Playback"
    case recording = "Recording"

    var id: String { rawValue }
}

struct AudioDevice: Identifiable, Hashable {
    let id: String
    var coreAudioObjectID: AudioObjectID?
    var name: String
    var description: String
    var iconName: String
    var isDefault: Bool
    var volume: Double
    var isMuted: Bool
    var supportsVolume: Bool
    var supportsMute: Bool
    var isLocked: Bool
    var selectedPort: String
    var availablePorts: [String]
    var channels: [AudioChannel]
}

struct AudioChannel: Identifiable, Hashable {
    let id: String
    var name: String
    var volume: Double
}

struct AppAudioStream: Identifiable, Hashable {
    let id: String
    var preferenceKey: String
    var processID: Int32?
    var bundleID: String?
    var isVirtualStream: Bool
    var appName: String
    var detail: String
    var iconName: String
    var direction: StreamDirection
    var volume: Double
    var isMuted: Bool
    var isLocked: Bool
    var assignedDeviceID: AudioDevice.ID?
    var requestedDeviceID: AudioDevice.ID?
    var routeSelectionID: AudioDevice.ID?
    var routingStatus: String?
}

extension AppAudioStream {
    var isInputMonitorStream: Bool {
        id.hasPrefix("org.moroz.xavucontrol.input-monitor.")
    }
}

struct AudioRouteRequest: Identifiable, Hashable {
    let id: String
    var streamID: AppAudioStream.ID
    var direction: StreamDirection
    var targetDeviceID: AudioDevice.ID
    var status: RoutingStatus

    init(streamID: AppAudioStream.ID, direction: StreamDirection, targetDeviceID: AudioDevice.ID, status: RoutingStatus) {
        self.id = "\(streamID)-\(targetDeviceID)"
        self.streamID = streamID
        self.direction = direction
        self.targetDeviceID = targetDeviceID
        self.status = status
    }
}

enum RoutingStatus: Hashable {
    case pending
    case queued(String)
    case active(String)
    case unsupported(String)
    case failed(String)

    var displayText: String {
        switch self {
        case .pending:
            return "Routing request pending"
        case .queued(let detail):
            return detail
        case .active(let detail):
            return detail
        case .unsupported(let reason):
            return reason
        case .failed(let reason):
            return reason
        }
    }
}

struct AudioProfile: Identifiable, Hashable {
    let id: String
    var deviceName: String
    var selectedProfile: String
    var availableProfiles: [String]
}

enum DeviceKind {
    case output
    case input

    var volumeLabel: String {
        switch self {
        case .output: "Output Volume:"
        case .input: "Input Volume:"
        }
    }

    var audioDirection: AudioDeviceDirection {
        switch self {
        case .output: .output
        case .input: .input
        }
    }
}

extension AudioDevice {
    nonisolated var isXavucontrolVirtualDevice: Bool {
        isXavucontrolVirtualEndpoint || isXavucontrolTapDevice
    }

    nonisolated var isXavucontrolVirtualEndpoint: Bool {
        name.localizedCaseInsensitiveContains(SetupState.virtualCableName)
            || name.localizedCaseInsensitiveContains(SetupState.virtualMicName)
    }

    nonisolated var isXavucontrolTapDevice: Bool {
        name.localizedCaseInsensitiveContains("Xavucontrol Tap")
            || name.localizedCaseInsensitiveContains("Xavucontrol Global Tap")
    }
}

@MainActor
final class AudioModel: ObservableObject {
    @Published var outputDevices: [AudioDevice]
    @Published var inputDevices: [AudioDevice]
    @Published var streams: [AppAudioStream]
    @Published var profiles: [AudioProfile]
    @Published var deviceDiscoveryStatus: String
    @Published var streamDiscoveryStatus: String
    @Published var realtimeStatus: String
    @Published var routingStatus: String
    @Published var routeRequests: [AudioRouteRequest]
    @Published var setupState: SetupState
    @Published var appPreferences: AppPreferences
    @Published var launchAtLoginEnabled: Bool
    @Published var launchAtLoginStatus: String

    private let deviceProvider = CoreAudioDeviceProvider()
    private let processProvider = AudioProcessProvider()
    private let routingEngine = RoutingEngine(backend: VirtualAudioRoutingBackend())
    private let driverInstaller = DriverInstaller()
    private let preferenceStore = AppPreferenceStore()
    private let loginItemService = LoginItemService()
    private var realtimeObserver: CoreAudioRealtimeObserver?
    private var isRefreshingDevices = false
    private var isRefreshingStreams = false
    private var routeGenerationByRouteID: [AudioRouteRequest.ID: Int] = [:]
    private var activePlaybackRouteTargetIDsByPreferenceKey: [String: Set<AudioDevice.ID>] = [:]
    private var activePlaybackRouteStreamIDByPreferenceKey: [String: AppAudioStream.ID] = [:]

    init() {
        outputDevices = []
        inputDevices = []
        streams = []
        profiles = []
        deviceDiscoveryStatus = "Core Audio devices not loaded yet"
        streamDiscoveryStatus = "Core Audio processes not loaded yet"
        realtimeStatus = "Live Core Audio updates starting..."
        routingStatus = routingEngine.backendStatus
        routeRequests = []
        setupState = .initial
        appPreferences = preferenceStore.load()
        let loginItemSnapshot = loginItemService.snapshot()
        launchAtLoginEnabled = loginItemSnapshot.isEnabled
        launchAtLoginStatus = loginItemSnapshot.statusText
        Task { [weak self] in
            self?.refreshDevices()
            self?.startRealtimeObservation()
        }
    }

    func refreshDevices() {
        guard !isRefreshingDevices else { return }
        isRefreshingDevices = true
        deviceDiscoveryStatus = "Loading Core Audio devices..."

        let deviceProvider = deviceProvider
        let processProvider = processProvider
        Task.detached { [weak self] in
            let discoveredOutputs = deviceProvider.loadDevices(direction: .output)
            let discoveredInputs = deviceProvider.loadDevices(direction: .input)
            let playbackStreams = processProvider.loadStreams(
                direction: .playback,
                outputDevices: discoveredOutputs,
                inputDevices: discoveredInputs
            )
            let recordingStreams = processProvider.loadStreams(
                direction: .recording,
                outputDevices: discoveredOutputs,
                inputDevices: discoveredInputs
            )

            await MainActor.run {
                guard let self else { return }
                self.isRefreshingDevices = false
                self.outputDevices = discoveredOutputs
                self.inputDevices = discoveredInputs

                if !discoveredOutputs.isEmpty || !discoveredInputs.isEmpty {
                    self.profiles = self.makeProfiles(outputDevices: discoveredOutputs, inputDevices: discoveredInputs)
                    self.deviceDiscoveryStatus = "Loaded \(discoveredOutputs.count) output device(s), \(discoveredInputs.count) input device(s) from Core Audio"
                } else {
                    self.profiles = []
                    self.deviceDiscoveryStatus = "Core Audio returned no devices"
                }

                self.refreshSetupDiagnostics()
                self.applyStreams(playbackStreams: playbackStreams, recordingStreams: recordingStreams)
                self.configureInputMonitorsFromPreferences()
            }
        }
    }

    func refreshStreams() {
        guard !isRefreshingStreams else { return }
        isRefreshingStreams = true
        streamDiscoveryStatus = "Loading Core Audio processes..."

        let processProvider = processProvider
        let outputDevices = outputDevices
        let inputDevices = inputDevices
        Task.detached { [weak self] in
            let playbackStreams = processProvider.loadStreams(
                direction: .playback,
                outputDevices: outputDevices,
                inputDevices: inputDevices
            )
            let recordingStreams = processProvider.loadStreams(
                direction: .recording,
                outputDevices: outputDevices,
                inputDevices: inputDevices
            )

            await MainActor.run {
                guard let self else { return }
                self.isRefreshingStreams = false
                self.applyStreams(playbackStreams: playbackStreams, recordingStreams: recordingStreams)
            }
        }
    }

    private func applyStreams(playbackStreams: [AppAudioStream], recordingStreams: [AppAudioStream]) {
        let existingStreamsByID = Dictionary(uniqueKeysWithValues: streams.map { ($0.id, $0) })
        let existingStreamsByPreferenceKey = Dictionary(grouping: streams, by: \.preferenceKey)

        let liveStreams = (playbackStreams + recordingStreams).map { stream in
            var updatedStream = stream
            if let existingStream = existingStreamsByID[stream.id] ?? existingStreamsByPreferenceKey[stream.preferenceKey]?.first {
                updatedStream.volume = existingStream.volume
                updatedStream.isMuted = existingStream.isMuted
                updatedStream.requestedDeviceID = existingStream.requestedDeviceID
                updatedStream.routeSelectionID = existingStream.routeSelectionID
                updatedStream.routingStatus = existingStream.routingStatus
            }
            if let preferredVolume = appPreferences.streamVolumes[stream.preferenceKey] {
                updatedStream.volume = preferredVolume
            }
            if let preferredMuted = appPreferences.streamMutedStates[stream.preferenceKey] {
                updatedStream.isMuted = preferredMuted
            }
            if let routeRequest = routeRequests.first(where: { $0.streamID == stream.id }) {
                updatedStream.requestedDeviceID = routeRequest.targetDeviceID
                updatedStream.routingStatus = routeRequest.status.displayText
                updatedStream.routeSelectionID = preferredRouteSelectionID(for: updatedStream)
            } else if let activeTargetIDs = activePlaybackRouteTargetIDsByPreferenceKey[stream.preferenceKey],
                      !activeTargetIDs.isEmpty,
                      stream.direction == .playback {
                updatedStream.requestedDeviceID = activeTargetIDs.first
                updatedStream.routeSelectionID = preferredRouteSelectionID(for: updatedStream)
                let targetNames = activeTargetIDs
                    .compactMap { targetID in outputDevices.first(where: { $0.id == targetID })?.name }
                    .sorted()
                updatedStream.routingStatus = "Active route: \(targetNames.joined(separator: ", "))"
            } else if updatedStream.routeSelectionID == nil {
                updatedStream.routeSelectionID = preferredRouteSelectionID(for: updatedStream)
            }
            return updatedStream
        }
        let monitorStreams = inputMonitorStreams()
        streams = liveStreams + monitorStreams
        streamDiscoveryStatus = "Loaded \(playbackStreams.count + monitorStreams.count) playback stream(s), \(recordingStreams.count) recording process(es) from Core Audio"
        applyPreferredRoutesToPlaybackStreams()
        applyPreferredRoutesToRecordingStreams()
    }

    func requestRoute(streamID: AppAudioStream.ID, targetDeviceID: AudioDevice.ID) {
        guard let streamIndex = streams.firstIndex(where: { $0.id == streamID }) else {
            return
        }

        let stream = streams[streamIndex]
        if stream.direction == .recording {
            requestRecordingRoute(streamIndex: streamIndex, routeSelectionID: targetDeviceID)
            return
        }

        requestPlaybackRouteTargets(streamIndex: streamIndex, routeSelectionIDs: [targetDeviceID])
    }

    func requestPlaybackRouteTargets(streamID: AppAudioStream.ID, routeSelectionIDs: [AudioDevice.ID]) {
        guard let streamIndex = streams.firstIndex(where: { $0.id == streamID }) else {
            return
        }

        requestPlaybackRouteTargets(streamIndex: streamIndex, routeSelectionIDs: routeSelectionIDs)
    }

    func togglePlaybackRouteTarget(streamID: AppAudioStream.ID, targetDeviceID: AudioDevice.ID) {
        guard let streamIndex = streams.firstIndex(where: { $0.id == streamID }) else {
            return
        }

        let stream = streams[streamIndex]
        togglePlaybackRouteTarget(preferenceKey: stream.preferenceKey, targetDeviceID: targetDeviceID)
    }

    func togglePlaybackRouteTarget(preferenceKey: String, targetDeviceID: AudioDevice.ID) {
        let activeStreamID = activePlaybackRouteStreamIDByPreferenceKey[preferenceKey]
        guard let streamIndex = streams.firstIndex(where: { $0.id == activeStreamID })
            ?? streams.firstIndex(where: { $0.preferenceKey == preferenceKey && $0.direction == .playback && !$0.isVirtualStream }) else {
            return
        }

        let stream = streams[streamIndex]
        guard stream.direction == .playback,
              routableOutputDevice(id: targetDeviceID) != nil else {
            return
        }

        var selectedRouteIDs = preferredOutputRouteSelectionIDs(for: stream)
        if selectedRouteIDs.contains(targetDeviceID) {
            selectedRouteIDs.removeAll { $0 == targetDeviceID }
        } else {
            selectedRouteIDs.append(targetDeviceID)
        }

        NSLog(
            "Xavucontrol playback route toggle %@ target=%@ selected=%@",
            preferenceKey,
            targetDeviceID,
            selectedRouteIDs.joined(separator: ",")
        )
        requestPlaybackRouteTargets(streamIndex: streamIndex, routeSelectionIDs: selectedRouteIDs)
    }

    private func requestPlaybackRouteTargets(streamIndex: Int, routeSelectionIDs: [AudioDevice.ID]) {
        let stream = streams[streamIndex]
        guard stream.direction == .playback else {
            return
        }

        let selectedRouteIDs = normalizedPlaybackRouteSelectionIDs(routeSelectionIDs)
        if stream.direction == .playback {
            if selectedRouteIDs.count == 1,
               selectedRouteIDs.first == applicationDefaultOutputDevice()?.id {
                preferenceStore.setStreamOutputDeviceID(nil, for: stream.preferenceKey)
                preferenceStore.setStreamOutputTargetDeviceIDs(nil, for: stream.preferenceKey)
                appPreferences.streamOutputDeviceIDs.removeValue(forKey: stream.preferenceKey)
                appPreferences.streamOutputTargetDeviceIDs.removeValue(forKey: stream.preferenceKey)
            } else {
                preferenceStore.setStreamOutputDeviceID(nil, for: stream.preferenceKey)
                preferenceStore.setStreamOutputTargetDeviceIDs(selectedRouteIDs, for: stream.preferenceKey)
                appPreferences.streamOutputDeviceIDs.removeValue(forKey: stream.preferenceKey)
                appPreferences.streamOutputTargetDeviceIDs[stream.preferenceKey] = selectedRouteIDs
            }
        }

        let effectiveTargetDeviceIDs = effectiveOutputDeviceIDs(forRouteSelectionIDs: selectedRouteIDs)
        let targetDevices = effectiveTargetDeviceIDs.compactMap { routableOutputDevice(id: $0) }
        guard !targetDevices.isEmpty else {
            streams[streamIndex].routingStatus = "Target device is no longer available"
            streams[streamIndex].routeSelectionID = selectedRouteIDs.first
            return
        }

        if let reason = targetDevices.compactMap({ routeReadinessMessage(stream: stream, targetDevice: $0) }).first {
            streams[streamIndex].requestedDeviceID = targetDevices.first?.id
            streams[streamIndex].routeSelectionID = selectedRouteIDs.first
            streams[streamIndex].routingStatus = reason
            routingStatus = reason
            return
        }

        NSLog(
            "Xavucontrol playback route request %@ selected=%@ targets=%d [%@]",
            stream.preferenceKey,
            selectedRouteIDs.joined(separator: ","),
            targetDevices.count,
            targetDevices.map(\.name).joined(separator: ", ")
        )
        streams[streamIndex].requestedDeviceID = targetDevices.first?.id
        streams[streamIndex].routeSelectionID = selectedRouteIDs.first
        streams[streamIndex].routingStatus = RoutingStatus.pending.displayText
        routingStatus = RoutingStatus.pending.displayText

        stopDuplicatePlaybackRoutes(preferenceKey: stream.preferenceKey, keepingStreamID: stream.id)
        activePlaybackRouteTargetIDsByPreferenceKey[stream.preferenceKey] = Set(targetDevices.map(\.id))
        activePlaybackRouteStreamIDByPreferenceKey[stream.preferenceKey] = stream.id
        routeRequests.removeAll { $0.streamID == stream.id }
        let requests = targetDevices.map { targetDevice in
            AudioRouteRequest(
                streamID: stream.id,
                direction: stream.direction,
                targetDeviceID: targetDevice.id,
                status: .pending
            )
        }
        requests.forEach(upsertRouteRequest)
        let routeGeneration = nextRouteGeneration(routeID: stream.preferenceKey)

        Task {
            await applyRoutes(
                routeRequests: requests,
                streamID: stream.id,
                preferenceKey: stream.preferenceKey,
                targetDeviceIDs: targetDevices.map(\.id),
                routeGeneration: routeGeneration
            )
        }
    }

    private func requestRecordingRoute(streamIndex: Int, routeSelectionID: AudioDevice.ID) {
        let stream = streams[streamIndex]
        let effectiveTargetDeviceID = effectiveInputDeviceID(forRouteSelectionID: routeSelectionID)
        if routeSelectionID == AppPreferences.defaultInputRouteID {
            preferenceStore.setStreamInputDeviceID(nil, for: stream.preferenceKey)
            appPreferences.streamInputDeviceIDs.removeValue(forKey: stream.preferenceKey)
        } else {
            preferenceStore.setStreamInputDeviceID(routeSelectionID, for: stream.preferenceKey)
            appPreferences.streamInputDeviceIDs[stream.preferenceKey] = routeSelectionID
        }

        guard let targetDevice = routableInputDevice(id: effectiveTargetDeviceID) else {
            streams[streamIndex].routingStatus = "Target input device is no longer available"
            streams[streamIndex].routeSelectionID = routeSelectionID
            return
        }

        streams[streamIndex].requestedDeviceID = targetDevice.id
        streams[streamIndex].routeSelectionID = routeSelectionID
        startRecordingBridge(sourceDevice: targetDevice, routeSelectionID: routeSelectionID)
    }

    func updateStreamVolume(streamID: AppAudioStream.ID, volume: Double) {
        guard let streamIndex = streams.firstIndex(where: { $0.id == streamID }) else {
            return
        }

        streams[streamIndex].volume = volume
        let stream = streams[streamIndex]
        preferenceStore.setStreamVolume(volume, for: stream.preferenceKey)
        appPreferences.streamVolumes[stream.preferenceKey] = max(0, min(1, volume))
        Task {
            let result = await routingEngine.setStreamVolume(stream: stream, volume: volume)
            routingStatus = RoutingStatus(result: result).displayText
        }
    }

    func updateStreamMuted(streamID: AppAudioStream.ID, isMuted: Bool) {
        guard let streamIndex = streams.firstIndex(where: { $0.id == streamID }) else {
            return
        }

        streams[streamIndex].isMuted = isMuted
        let stream = streams[streamIndex]
        preferenceStore.setStreamMuted(isMuted, for: stream.preferenceKey)
        appPreferences.streamMutedStates[stream.preferenceKey] = isMuted
        Task {
            let result = await routingEngine.setStreamMuted(stream: stream, isMuted: isMuted)
            routingStatus = RoutingStatus(result: result).displayText
        }
    }

    func isInputDeviceIncludedInVirtualMic(deviceID: AudioDevice.ID) -> Bool {
        appPreferences.virtualMicInputDeviceIDs.contains(deviceID)
    }

    func setInputDeviceIncludedInVirtualMic(deviceID: AudioDevice.ID, isIncluded: Bool) {
        guard inputDevices.contains(where: { $0.id == deviceID && !$0.isXavucontrolVirtualDevice }) else {
            return
        }

        preferenceStore.setVirtualMicInputDeviceEnabled(isIncluded, deviceID: deviceID)
        if isIncluded {
            appPreferences.virtualMicInputDeviceIDs.insert(deviceID)
        } else {
            appPreferences.virtualMicInputDeviceIDs.remove(deviceID)
        }
        configureVirtualMicrophoneBridgeFromPreferences()
    }

    func isPlaybackStreamIncludedInVirtualMic(_ stream: AppAudioStream) -> Bool {
        appPreferences.virtualMicPlaybackStreamKeys.contains(stream.preferenceKey)
    }

    func setPlaybackStreamIncludedInVirtualMic(streamID: AppAudioStream.ID, isIncluded: Bool) {
        guard let stream = streams.first(where: { $0.id == streamID }),
              stream.direction == .playback,
              !stream.isVirtualStream else {
            return
        }

        preferenceStore.setVirtualMicPlaybackStreamEnabled(isIncluded, preferenceKey: stream.preferenceKey)
        if isIncluded {
            appPreferences.virtualMicPlaybackStreamKeys.insert(stream.preferenceKey)
        } else {
            appPreferences.virtualMicPlaybackStreamKeys.remove(stream.preferenceKey)
        }
        configureVirtualMicrophoneBridgeFromPreferences()
    }

    func inputMonitorOutputDeviceID(for inputDeviceID: AudioDevice.ID) -> AudioDevice.ID? {
        appPreferences.inputMonitorOutputDeviceIDs[inputDeviceID]
    }

    func setInputMonitorOutputDeviceID(inputDeviceID: AudioDevice.ID, outputDeviceID: AudioDevice.ID?) {
        guard inputDevices.contains(where: { $0.id == inputDeviceID && !$0.isXavucontrolVirtualDevice }) else {
            return
        }
        if let outputDeviceID {
            guard outputDevices.contains(where: { $0.id == outputDeviceID && !$0.isXavucontrolVirtualDevice }) else {
                return
            }
        }

        preferenceStore.setInputMonitorOutputDeviceID(outputDeviceID, inputDeviceID: inputDeviceID)
        if let outputDeviceID {
            appPreferences.inputMonitorOutputDeviceIDs[inputDeviceID] = outputDeviceID
        } else {
            appPreferences.inputMonitorOutputDeviceIDs.removeValue(forKey: inputDeviceID)
        }

        refreshInputMonitorStreams()
        configureInputMonitorsFromPreferences()
    }

    func setApplicationDefaultOutputDevice(deviceID: AudioDevice.ID) {
        guard outputDevices.contains(where: { $0.id == deviceID && !$0.isXavucontrolVirtualDevice }) else {
            return
        }

        preferenceStore.setDefaultOutputDeviceID(deviceID)
        appPreferences.defaultOutputDeviceID = deviceID
        rerouteDefaultPlaybackStreams()
    }

    func setApplicationDefaultInputDevice(deviceID: AudioDevice.ID) {
        guard inputDevices.contains(where: { $0.id == deviceID && !$0.isXavucontrolVirtualDevice }) else {
            return
        }

        preferenceStore.setDefaultInputDeviceID(deviceID)
        appPreferences.defaultInputDeviceID = deviceID
        rerouteDefaultRecordingStreams()
    }

    func setSystemDefaultDevice(deviceID: AudioDevice.ID, kind: DeviceKind) {
        guard let device = device(kind: kind, id: deviceID),
              let coreAudioObjectID = device.coreAudioObjectID,
              deviceProvider.setDefaultDevice(coreAudioObjectID, direction: kind.audioDirection) else {
            deviceDiscoveryStatus = "Unable to set system default device"
            return
        }

        refreshDevices()
    }

    func resetPreferences() {
        preferenceStore.reset()
        appPreferences = preferenceStore.load()
        routeRequests.removeAll()
        Task {
            await InputMonitorService.shared.stopAll()
        }
        for index in streams.indices where streams[index].direction == .playback || streams[index].direction == .recording {
            streams[index].requestedDeviceID = nil
            streams[index].routeSelectionID = preferredRouteSelectionID(for: streams[index])
            streams[index].routingStatus = nil
        }
        streams.removeAll { $0.isInputMonitorStream }
        applyPreferredRoutesToPlaybackStreams()
        applyPreferredRoutesToRecordingStreams()
    }

    func routeSelectionID(for stream: AppAudioStream) -> AudioDevice.ID {
        stream.routeSelectionID ?? preferredRouteSelectionID(for: stream)
    }

    func routeSelectionIDs(for stream: AppAudioStream) -> [AudioDevice.ID] {
        guard stream.direction == .playback else {
            return [routeSelectionID(for: stream)]
        }
        return preferredOutputRouteSelectionIDs(for: stream)
    }

    func applicationDefaultOutputDeviceName() -> String {
        guard let device = applicationDefaultOutputDevice() else {
            return "No available output device"
        }
        return device.name
    }

    func applicationDefaultInputDeviceName() -> String {
        guard let device = applicationDefaultInputDevice() else {
            return "No available input device"
        }
        return device.name
    }

    func isApplicationDefaultOutputDevice(_ device: AudioDevice) -> Bool {
        applicationDefaultOutputDevice()?.id == device.id
    }

    func isApplicationDefaultInputDevice(_ device: AudioDevice) -> Bool {
        applicationDefaultInputDevice()?.id == device.id
    }

    private func applyRoute(
        routeRequest: AudioRouteRequest,
        streamID: AppAudioStream.ID,
        targetDeviceID: AudioDevice.ID,
        routeGeneration: Int
    ) async {
        guard routeGenerationByRouteID[routeRequest.id] == routeGeneration else {
            return
        }

        guard let stream = streams.first(where: { $0.id == streamID }) else {
            return
        }

        let devices = stream.direction == .playback ? outputDevices : inputDevices
        guard let targetDevice = devices.first(where: { $0.id == targetDeviceID }) else {
            let status = RoutingStatus.failed("Target device is no longer available")
            updateRouteStatus(routeRequest: routeRequest, status: status)
            return
        }

        let result = await routingEngine.apply(
            routeRequest: routeRequest,
            stream: stream,
            targetDevice: targetDevice
        )
        guard routeGenerationByRouteID[routeRequest.id] == routeGeneration else {
            return
        }
        updateRouteStatus(routeRequest: routeRequest, status: RoutingStatus(result: result))
    }

    private func applyRoutes(
        routeRequests: [AudioRouteRequest],
        streamID: AppAudioStream.ID,
        preferenceKey: String,
        targetDeviceIDs: [AudioDevice.ID],
        routeGeneration: Int
    ) async {
        guard routeGenerationByRouteID[preferenceKey] == routeGeneration else {
            return
        }

        guard let stream = streams.first(where: { $0.id == streamID }) else {
            return
        }

        let targetDevices = targetDeviceIDs.compactMap { targetDeviceID in
            outputDevices.first(where: { $0.id == targetDeviceID })
        }
        guard !targetDevices.isEmpty else {
            updateRouteStatuses(routeRequests: routeRequests, status: .failed("Target device is no longer available"))
            return
        }

        let result = await routingEngine.apply(
            routeRequests: routeRequests,
            stream: stream,
            targetDevices: targetDevices
        )
        guard routeGenerationByRouteID[preferenceKey] == routeGeneration else {
            return
        }
        updateRouteStatuses(routeRequests: routeRequests, status: RoutingStatus(result: result))
    }

    private func nextRouteGeneration(routeID: AudioRouteRequest.ID) -> Int {
        let nextGeneration = (routeGenerationByRouteID[routeID] ?? 0) + 1
        routeGenerationByRouteID[routeID] = nextGeneration
        return nextGeneration
    }

    private func refreshInputMonitorStreams() {
        streams.removeAll { $0.isInputMonitorStream }
        streams.append(contentsOf: inputMonitorStreams())
    }

    private func inputMonitorStreams() -> [AppAudioStream] {
        inputDevices.compactMap { inputDevice in
            guard !inputDevice.isXavucontrolVirtualDevice,
                  let outputDeviceID = appPreferences.inputMonitorOutputDeviceIDs[inputDevice.id],
                  let outputDevice = outputDevices.first(where: { $0.id == outputDeviceID && !$0.isXavucontrolVirtualDevice }) else {
                return nil
            }

            return AppAudioStream(
                id: "org.moroz.xavucontrol.input-monitor.\(inputDevice.id)",
                preferenceKey: "input-monitor:\(inputDevice.id)",
                processID: nil,
                bundleID: nil,
                isVirtualStream: true,
                appName: "Listen: \(inputDevice.name)",
                detail: "Input monitor",
                iconName: inputDevice.iconName,
                direction: .playback,
                volume: 1,
                isMuted: false,
                isLocked: true,
                assignedDeviceID: outputDevice.id,
                requestedDeviceID: outputDevice.id,
                routeSelectionID: outputDevice.id,
                routingStatus: "Listening on \(outputDevice.name)"
            )
        }
    }

    private func configureInputMonitorsFromPreferences() {
        let inputDevices = inputDevices
        let outputDevices = outputDevices
        let routes = appPreferences.inputMonitorOutputDeviceIDs
        Task {
            let status = await InputMonitorService.shared.reconcile(
                inputDevices: inputDevices,
                outputDevices: outputDevices,
                routes: routes
            )
            await MainActor.run {
                self.routingStatus = status
                self.refreshInputMonitorStreams()
            }
        }
    }

    private func routeReadinessMessage(stream: AppAudioStream, targetDevice: AudioDevice) -> String? {
        guard stream.direction == .playback else {
            return nil
        }

        if targetDevice.id == setupState.virtualCableOutputID {
            return "Choose a physical output device; Virtual Cable is the capture source"
        }

        guard setupState.isVirtualOutputDefault || streamUsesXavucontrolVirtualDevice(stream) else {
            return "Set system output to \(SetupState.virtualCableName) or choose \(SetupState.virtualCableName) inside the source app"
        }

        return nil
    }

    func streamUsesXavucontrolVirtualDevice(_ stream: AppAudioStream) -> Bool {
        let devices = stream.direction == .playback ? outputDevices : inputDevices
        guard let assignedDeviceID = stream.assignedDeviceID,
              let assignedDevice = devices.first(where: { $0.id == assignedDeviceID }) else {
            return false
        }

        if stream.direction == .playback {
            return assignedDevice.id == setupState.virtualCableOutputID
                || assignedDevice.name.localizedCaseInsensitiveContains(SetupState.virtualCableName)
        }

        return assignedDevice.id == setupState.virtualCableInputID
            || assignedDevice.name.localizedCaseInsensitiveContains(SetupState.virtualMicName)
    }

    private func preferredRouteSelectionID(for stream: AppAudioStream) -> AudioDevice.ID {
        guard stream.direction == .playback else {
            if let preferredDeviceID = appPreferences.streamInputDeviceIDs[stream.preferenceKey],
               routableInputDevice(id: preferredDeviceID) != nil {
                return preferredDeviceID
            }
            return AppPreferences.defaultInputRouteID
        }

        return preferredOutputRouteSelectionIDs(for: stream).first ?? applicationDefaultOutputDevice()?.id ?? AppPreferences.defaultOutputRouteID
    }

    private func preferredOutputRouteSelectionIDs(for stream: AppAudioStream) -> [AudioDevice.ID] {
        if let activeDeviceIDs = activePlaybackRouteTargetIDsByPreferenceKey[stream.preferenceKey],
           !activeDeviceIDs.isEmpty {
            let availableDeviceIDs = activeDeviceIDs.filter { routableOutputDevice(id: $0) != nil }
            if !availableDeviceIDs.isEmpty {
                return normalizedPlaybackRouteSelectionIDs(Array(availableDeviceIDs))
            }
        }

        if let preferredDeviceIDs = appPreferences.streamOutputTargetDeviceIDs[stream.preferenceKey] {
            let availableDeviceIDs = preferredDeviceIDs.filter { routableOutputDevice(id: $0) != nil }
            if !availableDeviceIDs.isEmpty {
                return normalizedPlaybackRouteSelectionIDs(availableDeviceIDs)
            }
        }

        if appPreferences.streamOutputTargetDeviceIDs[stream.preferenceKey] == nil,
           let preferredDeviceID = appPreferences.streamOutputDeviceIDs[stream.preferenceKey],
           routableOutputDevice(id: preferredDeviceID) != nil {
            return [preferredDeviceID]
        }

        guard let defaultOutputDevice = applicationDefaultOutputDevice() else {
            return []
        }
        return [defaultOutputDevice.id]
    }

    private func normalizedPlaybackRouteSelectionIDs(_ routeSelectionIDs: [AudioDevice.ID]) -> [AudioDevice.ID] {
        let nonEmptyIDs = routeSelectionIDs
            .filter { !$0.isEmpty && $0 != AppPreferences.defaultOutputRouteID }
        guard !nonEmptyIDs.isEmpty else {
            return applicationDefaultOutputDevice().map { [$0.id] } ?? []
        }

        var uniqueIDs: [AudioDevice.ID] = []
        for routeSelectionID in nonEmptyIDs where !uniqueIDs.contains(routeSelectionID) {
            uniqueIDs.append(routeSelectionID)
        }
        return uniqueIDs
    }

    private func effectiveOutputDeviceID(forRouteSelectionID routeSelectionID: AudioDevice.ID) -> AudioDevice.ID {
        if routeSelectionID == AppPreferences.defaultOutputRouteID {
            return applicationDefaultOutputDevice()?.id ?? routeSelectionID
        }
        return routeSelectionID
    }

    private func effectiveOutputDeviceIDs(forRouteSelectionIDs routeSelectionIDs: [AudioDevice.ID]) -> [AudioDevice.ID] {
        var effectiveIDs: [AudioDevice.ID] = []
        for routeSelectionID in normalizedPlaybackRouteSelectionIDs(routeSelectionIDs) {
            let effectiveID = effectiveOutputDeviceID(forRouteSelectionID: routeSelectionID)
            if !effectiveIDs.contains(effectiveID) {
                effectiveIDs.append(effectiveID)
            }
        }
        return effectiveIDs
    }

    private func effectiveInputDeviceID(forRouteSelectionID routeSelectionID: AudioDevice.ID) -> AudioDevice.ID {
        if routeSelectionID == AppPreferences.defaultInputRouteID {
            return applicationDefaultInputDevice()?.id ?? routeSelectionID
        }
        return routeSelectionID
    }

    private func applicationDefaultOutputDevice() -> AudioDevice? {
        if let preferredID = appPreferences.defaultOutputDeviceID,
           let preferredDevice = routableOutputDevice(id: preferredID) {
            return preferredDevice
        }

        return outputDevices.first { device in
            !device.isXavucontrolVirtualDevice
                && (device.id.localizedCaseInsensitiveContains("BuiltInSpeakerDevice")
                    || device.name.localizedCaseInsensitiveContains("MacBook Pro Speakers")
                    || device.name.localizedCaseInsensitiveContains("Speakers"))
        } ?? outputDevices.first { !$0.isXavucontrolVirtualDevice }
    }

    private func applicationDefaultInputDevice() -> AudioDevice? {
        if let preferredID = appPreferences.defaultInputDeviceID,
           let preferredDevice = routableInputDevice(id: preferredID) {
            return preferredDevice
        }

        return inputDevices.first { device in
            !device.isXavucontrolVirtualDevice
                && (device.id.localizedCaseInsensitiveContains("BuiltInMicrophoneDevice")
                    || device.name.localizedCaseInsensitiveContains("MacBook Pro Microphone")
                    || device.name.localizedCaseInsensitiveContains("Microphone"))
        } ?? inputDevices.first { !$0.isXavucontrolVirtualDevice }
    }

    private func routableOutputDevice(id: AudioDevice.ID) -> AudioDevice? {
        outputDevices.first { $0.id == id && !$0.isXavucontrolVirtualDevice }
    }

    private func routableInputDevice(id: AudioDevice.ID) -> AudioDevice? {
        inputDevices.first { $0.id == id && !$0.isXavucontrolVirtualDevice }
    }

    private func applyPreferredRoutesToPlaybackStreams() {
        let routeablePlaybackGroups = Dictionary(
            grouping: streams.filter { $0.direction == .playback && !$0.isVirtualStream },
            by: \.preferenceKey
        )

        for groupedStreams in routeablePlaybackGroups.values {
            guard let stream = groupedStreams.first(where: { candidate in
                routeRequests.contains { $0.streamID == candidate.id }
            }) ?? groupedStreams.first else {
                continue
            }

            let routeSelectionIDs = preferredOutputRouteSelectionIDs(for: stream)
            let targetDeviceIDs = effectiveOutputDeviceIDs(forRouteSelectionIDs: routeSelectionIDs)
            guard targetDeviceIDs.contains(where: { routableOutputDevice(id: $0) != nil }) else {
                markRouteUnavailable(streamID: stream.id, routeSelectionID: routeSelectionIDs.first ?? AppPreferences.defaultOutputRouteID)
                continue
            }

            let requestedTargetIDs = Set(targetDeviceIDs)
            if activePlaybackRouteTargetIDsByPreferenceKey[stream.preferenceKey] == requestedTargetIDs,
               activePlaybackRouteStreamIDByPreferenceKey[stream.preferenceKey] != nil {
                continue
            }

            stopDuplicatePlaybackRoutes(preferenceKey: stream.preferenceKey, keepingStreamID: stream.id)
            startRoutes(streamID: stream.id, routeSelectionIDs: routeSelectionIDs, targetDeviceIDs: targetDeviceIDs)
        }
    }

    private func rerouteDefaultPlaybackStreams() {
        for stream in streams where stream.direction == .playback && !stream.isVirtualStream {
            guard appPreferences.streamOutputDeviceIDs[stream.preferenceKey] == nil,
                  appPreferences.streamOutputTargetDeviceIDs[stream.preferenceKey] == nil else {
                continue
            }
            let routeSelectionIDs = preferredOutputRouteSelectionIDs(for: stream)
            startRoutes(
                streamID: stream.id,
                routeSelectionIDs: routeSelectionIDs,
                targetDeviceIDs: effectiveOutputDeviceIDs(forRouteSelectionIDs: routeSelectionIDs)
            )
        }
    }

    private func applyPreferredRoutesToRecordingStreams() {
        configureVirtualMicrophoneBridgeFromPreferences()
    }

    private func rerouteDefaultRecordingStreams() {
        configureVirtualMicrophoneBridgeFromPreferences()
    }

    private func markRecordingRouteUnavailable(streamID: AppAudioStream.ID, routeSelectionID: AudioDevice.ID) {
        guard let streamIndex = streams.firstIndex(where: { $0.id == streamID }) else {
            return
        }
        streams[streamIndex].routeSelectionID = routeSelectionID
        streams[streamIndex].routingStatus = "Preferred input device is not available"
    }

    private func startRecordingBridge(sourceDevice: AudioDevice, routeSelectionID: AudioDevice.ID) {
        for index in streams.indices where streams[index].direction == .recording && !streams[index].isVirtualStream {
            streams[index].requestedDeviceID = sourceDevice.id
            streams[index].routeSelectionID = preferredRouteSelectionID(for: streams[index])
            streams[index].routingStatus = "Starting virtual microphone bridge..."
        }
        routingStatus = "Starting virtual microphone bridge..."
        configureVirtualMicrophoneBridge(inputSources: [sourceDevice], playbackSources: [])
    }

    private func markRouteUnavailable(streamID: AppAudioStream.ID, routeSelectionID: AudioDevice.ID) {
        guard let streamIndex = streams.firstIndex(where: { $0.id == streamID }) else {
            return
        }
        streams[streamIndex].routeSelectionID = routeSelectionID
        streams[streamIndex].routingStatus = "Preferred output device is not available"
    }

    private func startRoute(streamID: AppAudioStream.ID, routeSelectionID: AudioDevice.ID, targetDeviceID: AudioDevice.ID) {
        startRoutes(streamID: streamID, routeSelectionIDs: [routeSelectionID], targetDeviceIDs: [targetDeviceID])
    }

    private func startRoutes(streamID: AppAudioStream.ID, routeSelectionIDs: [AudioDevice.ID], targetDeviceIDs: [AudioDevice.ID]) {
        guard let streamIndex = streams.firstIndex(where: { $0.id == streamID }) else {
            return
        }

        let stream = streams[streamIndex]
        let targetDevices = targetDeviceIDs.compactMap { routableOutputDevice(id: $0) }
        guard stream.direction == .playback, !targetDevices.isEmpty else {
            markRouteUnavailable(streamID: streamID, routeSelectionID: routeSelectionIDs.first ?? AppPreferences.defaultOutputRouteID)
            return
        }

        if let reason = targetDevices.compactMap({ routeReadinessMessage(stream: stream, targetDevice: $0) }).first {
            streams[streamIndex].requestedDeviceID = targetDevices.first?.id
            streams[streamIndex].routeSelectionID = routeSelectionIDs.first
            streams[streamIndex].routingStatus = reason
            routingStatus = reason
            return
        }

        streams[streamIndex].requestedDeviceID = targetDevices.first?.id
        streams[streamIndex].routeSelectionID = routeSelectionIDs.first
        streams[streamIndex].routingStatus = RoutingStatus.pending.displayText
        routingStatus = RoutingStatus.pending.displayText

        let requestedTargetIDs = Set(targetDevices.map(\.id))
        activePlaybackRouteTargetIDsByPreferenceKey[stream.preferenceKey] = requestedTargetIDs
        activePlaybackRouteStreamIDByPreferenceKey[stream.preferenceKey] = stream.id
        routeRequests.removeAll { $0.streamID == stream.id }
        let requests = targetDevices.map { targetDevice in
            AudioRouteRequest(
                streamID: stream.id,
                direction: stream.direction,
                targetDeviceID: targetDevice.id,
                status: .pending
            )
        }
        requests.forEach(upsertRouteRequest)
        let routeGeneration = nextRouteGeneration(routeID: stream.preferenceKey)

        Task {
            await applyRoutes(
                routeRequests: requests,
                streamID: stream.id,
                preferenceKey: stream.preferenceKey,
                targetDeviceIDs: targetDevices.map(\.id),
                routeGeneration: routeGeneration
            )
        }
    }

    private func stopRemovedPlaybackRoutes(stream: AppAudioStream, activeTargetDeviceIDs: Set<AudioDevice.ID>) {
        let staleRequests = routeRequests.filter {
            $0.streamID == stream.id && !activeTargetDeviceIDs.contains($0.targetDeviceID)
        }
        guard !staleRequests.isEmpty else {
            return
        }

        routeRequests.removeAll { request in
            request.streamID == stream.id && !activeTargetDeviceIDs.contains(request.targetDeviceID)
        }

        Task {
            for request in staleRequests {
                await ProcessTapRoutingService.shared.stop(streamID: stream.id, targetDeviceID: request.targetDeviceID)
                await VirtualCableRoutingService.shared.stop(streamID: stream.id)
            }
        }
    }

    private func stopDuplicatePlaybackRoutes(preferenceKey: String, keepingStreamID: AppAudioStream.ID) {
        if let activeStreamID = activePlaybackRouteStreamIDByPreferenceKey[preferenceKey],
           activeStreamID != keepingStreamID {
            activePlaybackRouteStreamIDByPreferenceKey[preferenceKey] = keepingStreamID
            Task {
                await ProcessTapRoutingService.shared.stop(streamID: activeStreamID)
                await VirtualCableRoutingService.shared.stop(streamID: activeStreamID)
            }
        }

        let duplicateStreamIDs = streams
            .filter {
                $0.direction == .playback
                    && !$0.isVirtualStream
                    && $0.preferenceKey == preferenceKey
                    && $0.id != keepingStreamID
            }
            .map(\.id)

        guard !duplicateStreamIDs.isEmpty else {
            return
        }

        routeRequests.removeAll { duplicateStreamIDs.contains($0.streamID) }
        Task {
            for duplicateStreamID in duplicateStreamIDs {
                await ProcessTapRoutingService.shared.stop(streamID: duplicateStreamID)
                await VirtualCableRoutingService.shared.stop(streamID: duplicateStreamID)
            }
        }
    }

    private func updateRouteStatus(routeRequest: AudioRouteRequest, status: RoutingStatus) {
        upsertRouteRequest(AudioRouteRequest(
            streamID: routeRequest.streamID,
            direction: routeRequest.direction,
            targetDeviceID: routeRequest.targetDeviceID,
            status: status
        ))

        if let streamIndex = streams.firstIndex(where: { $0.id == routeRequest.streamID }) {
            let streamRequests = routeRequests.filter { $0.streamID == routeRequest.streamID }
            streams[streamIndex].requestedDeviceID = streamRequests.first?.targetDeviceID ?? routeRequest.targetDeviceID
            streams[streamIndex].routeSelectionID = preferredRouteSelectionID(for: streams[streamIndex])
            if streamRequests.count > 1 {
                let activeCount = streamRequests.filter {
                    if case .active = $0.status { return true }
                    return false
                }.count
                let targetNames = streamRequests.compactMap { request in
                    outputDevices.first(where: { $0.id == request.targetDeviceID })?.name
                }
                streams[streamIndex].routingStatus = "Multi-output route \(activeCount)/\(streamRequests.count): \(targetNames.joined(separator: ", "))"
            } else {
                streams[streamIndex].routingStatus = status.displayText
            }
        }
        routingStatus = status.displayText
    }

    private func updateRouteStatuses(routeRequests: [AudioRouteRequest], status: RoutingStatus) {
        for routeRequest in routeRequests {
            upsertRouteRequest(AudioRouteRequest(
                streamID: routeRequest.streamID,
                direction: routeRequest.direction,
                targetDeviceID: routeRequest.targetDeviceID,
                status: status
            ))
        }

        guard let firstRequest = routeRequests.first else {
            routingStatus = status.displayText
            return
        }

        if let streamIndex = streams.firstIndex(where: { $0.id == firstRequest.streamID }) {
            streams[streamIndex].requestedDeviceID = routeRequests.first?.targetDeviceID
            streams[streamIndex].routeSelectionID = preferredRouteSelectionID(for: streams[streamIndex])
            if routeRequests.count > 1 {
                let targetNames = routeRequests.compactMap { request in
                    outputDevices.first(where: { $0.id == request.targetDeviceID })?.name
                }
                streams[streamIndex].routingStatus = "\(status.displayText) Outputs: \(targetNames.joined(separator: ", "))"
            } else {
                streams[streamIndex].routingStatus = status.displayText
            }
        }
        routingStatus = status.displayText
    }

    private func startRealtimeObservation() {
        let observer = CoreAudioRealtimeObserver(
            onDevicesChanged: { [weak self] in
                self?.refreshDevices()
            },
            onProcessesChanged: { [weak self] in
                self?.refreshStreams()
            }
        )
        realtimeObserver = observer
        observer.start()
        realtimeStatus = "Live Core Audio updates enabled"
    }

    func updateDeviceVolume(deviceID: AudioDevice.ID, kind: DeviceKind, volume: Double) {
        guard device(kind: kind, id: deviceID)?.supportsVolume == true else {
            return
        }

        updateDevice(deviceID: deviceID, kind: kind) { device in
            device.volume = volume
        }

        guard let device = device(kind: kind, id: deviceID),
              let coreAudioObjectID = device.coreAudioObjectID else {
            return
        }

        deviceProvider.setVolume(volume, deviceID: coreAudioObjectID, direction: kind.audioDirection)
    }

    func updateDeviceMuted(deviceID: AudioDevice.ID, kind: DeviceKind, isMuted: Bool) {
        guard device(kind: kind, id: deviceID)?.supportsMute == true else {
            return
        }

        updateDevice(deviceID: deviceID, kind: kind) { device in
            device.isMuted = isMuted
        }

        guard let device = device(kind: kind, id: deviceID),
              let coreAudioObjectID = device.coreAudioObjectID else {
            return
        }

        deviceProvider.setMuted(isMuted, deviceID: coreAudioObjectID, direction: kind.audioDirection)
    }

    func refreshSetupDiagnostics() {
        refreshLaunchAtLoginStatus()

        let virtualOutput = outputDevices.first { $0.name.localizedCaseInsensitiveContains(SetupState.virtualCableName) }
        let virtualInput = inputDevices.first {
            $0.name.localizedCaseInsensitiveContains(SetupState.virtualMicName)
                || $0.name.localizedCaseInsensitiveContains(SetupState.virtualCableName)
        }

        let hasOutput = virtualOutput != nil
        let hasInput = virtualInput != nil
        let isOutputDefault = virtualOutput?.isDefault == true
        let isInputDefault = virtualInput?.isDefault == true

        let installStatus: String
        if hasOutput && hasInput {
            installStatus = "Virtual cable output and virtual mic input are visible to Core Audio"
        } else if hasOutput || hasInput {
            installStatus = "Virtual cable/mic is partially visible to Core Audio"
        } else {
            installStatus = "Virtual cable not installed"
        }

        let defaultDeviceStatus: String
        if isOutputDefault && isInputDefault {
            defaultDeviceStatus = "Virtual cable is selected as default output and virtual mic is selected as default input"
        } else if isOutputDefault {
            defaultDeviceStatus = "Virtual cable is selected as default output"
        } else if isInputDefault {
            defaultDeviceStatus = "Virtual mic is selected as default input"
        } else {
            defaultDeviceStatus = "Virtual cable is not selected as a system default device"
        }

        let bundledDriverStatus = driverInstaller.bundledDriverURL() == nil
            ? "Latest built driver is not bundled in the app"
            : "Latest built driver is bundled in the app"

        let driverInputDiagnostic: SetupDiagnosticItem
        if let outputObjectID = virtualOutput?.coreAudioObjectID,
           let diagnostics = deviceProvider.virtualCableDiagnostics(deviceID: outputObjectID) {
            let detail = diagnostics.readStatus.isOK
                ? String(
                    format: "diagnostics v%u, starts %llu, will thread/cycle/write %llu/%llu/%llu, begin thread/cycle/write %llu/%llu/%llu, do write %llu, end thread/cycle/write %llu/%llu/%llu, frames %llu, peak %.5f, rms %.5f",
                    diagnostics.version,
                    diagnostics.startCount,
                    diagnostics.willThreadCount,
                    diagnostics.willCycleCount,
                    diagnostics.willWriteMixCount,
                    diagnostics.beginThreadCount,
                    diagnostics.beginCycleCount,
                    diagnostics.beginWriteMixCount,
                    diagnostics.doWriteMixCount,
                    diagnostics.endThreadCount,
                    diagnostics.endCycleCount,
                    diagnostics.endWriteMixCount,
                    diagnostics.capturedFrames,
                    diagnostics.peak,
                    diagnostics.rms
                )
                : diagnostics.readStatus.summary
            let state: SetupDiagnosticState
            if !diagnostics.readStatus.isOK {
                state = .warning
            } else if diagnostics.peak > 0.0001 || diagnostics.rms > 0.00001 {
                state = .ready
            } else if diagnostics.ioCycles > 0 || diagnostics.capturedFrames > 0 {
                state = .warning
            } else {
                state = .missing
            }

            driverInputDiagnostic = SetupDiagnosticItem(
                id: "driver-input",
                title: "Driver input",
                detail: detail,
                state: state
            )
        } else {
            driverInputDiagnostic = SetupDiagnosticItem(
                id: "driver-input",
                title: "Driver input",
                detail: hasOutput ? "Installed driver does not expose IO diagnostics; install latest bundled driver" : "Virtual cable output is not visible",
                state: hasOutput ? .warning : .missing
            )
        }

        setupState = SetupState(
            virtualCableOutputID: virtualOutput?.id,
            virtualCableInputID: virtualInput?.id,
            isVirtualOutputDefault: isOutputDefault,
            isVirtualInputDefault: isInputDefault,
            installStatus: installStatus,
            defaultDeviceStatus: defaultDeviceStatus,
            bundledDriverStatus: bundledDriverStatus,
            microphoneAccessStatus: setupState.microphoneAccessStatus,
            isInstalling: setupState.isInstalling,
            diagnostics: [
                SetupDiagnosticItem(
                    id: "driver",
                    title: "Virtual cable",
                    detail: installStatus,
                    state: hasOutput && hasInput ? .ready : hasOutput || hasInput ? .warning : .missing
                ),
                SetupDiagnosticItem(
                    id: "default-output",
                    title: "Default output",
                    detail: isOutputDefault ? "System output points at \(SetupState.virtualCableName)" : "System output does not point at \(SetupState.virtualCableName)",
                    state: isOutputDefault ? .ready : .missing
                ),
                SetupDiagnosticItem(
                    id: "default-input",
                    title: "Default input",
                    detail: isInputDefault ? "System input points at \(SetupState.virtualMicName)" : "System input does not point at \(SetupState.virtualMicName)",
                    state: isInputDefault ? .ready : .warning
                ),
                driverInputDiagnostic,
                SetupDiagnosticItem(
                    id: "microphone-access",
                    title: "Microphone access",
                    detail: setupState.microphoneAccessStatus,
                    state: setupState.microphoneAccessStatus.localizedCaseInsensitiveContains("granted") ? .ready : .warning
                ),
                SetupDiagnosticItem(
                    id: "router",
                    title: "Router backend",
                    detail: routingStatus,
                    state: .ready
                ),
                SetupDiagnosticItem(
                    id: "installer",
                    title: "Installer",
                    detail: bundledDriverStatus,
                    state: driverInstaller.bundledDriverURL() == nil ? .blocked : .ready
                )
            ]
        )
        updateRoutingReadinessStatus(hasOutput: hasOutput, hasInput: hasInput, isOutputDefault: isOutputDefault)
        applyPreferredRoutesToRecordingStreams()
    }

    func setLaunchAtLogin(_ isEnabled: Bool) {
        do {
            let snapshot = try loginItemService.setEnabled(isEnabled)
            launchAtLoginEnabled = snapshot.isEnabled
            launchAtLoginStatus = snapshot.statusText
        } catch {
            refreshLaunchAtLoginStatus()
            launchAtLoginStatus = "Unable to update launch at login: \(error.localizedDescription)"
        }
    }

    func refreshLaunchAtLoginStatus() {
        let snapshot = loginItemService.snapshot()
        launchAtLoginEnabled = snapshot.isEnabled
        launchAtLoginStatus = snapshot.statusText
    }

    func requestMicrophoneAccess() {
        setupState.microphoneAccessStatus = "Requesting microphone access..."
        Task {
            let status = await VirtualMicrophoneRoutingService.shared.requestMicrophoneAccess()
            setupState.microphoneAccessStatus = status
            refreshSetupDiagnostics()
            applyPreferredRoutesToRecordingStreams()
        }
    }

    private func configureVirtualMicrophoneBridgeFromPreferences() {
        guard setupState.virtualCableInputID != nil else {
            stopVirtualMicrophoneBridge(status: "Virtual mic is not available")
            return
        }

        guard hasActiveVirtualMicRecordingConsumer else {
            stopVirtualMicrophoneBridge(status: "Virtual mic idle; no recording app is currently using it")
            return
        }

        let selectedInputSources = inputDevices.filter {
            !$0.isXavucontrolVirtualDevice && appPreferences.virtualMicInputDeviceIDs.contains($0.id)
        }
        let selectedPlaybackSources = streams.filter {
            $0.direction == .playback
                && !$0.isVirtualStream
                && appPreferences.virtualMicPlaybackStreamKeys.contains($0.preferenceKey)
        }
        guard !selectedInputSources.isEmpty || !selectedPlaybackSources.isEmpty else {
            stopVirtualMicrophoneBridge(status: "Virtual mic has no enabled sources")
            return
        }

        configureVirtualMicrophoneBridge(inputSources: selectedInputSources, playbackSources: selectedPlaybackSources)
    }

    private var hasActiveVirtualMicRecordingConsumer: Bool {
        streams.contains { stream in
            stream.direction == .recording
                && !stream.isVirtualStream
                && streamUsesXavucontrolVirtualDevice(stream)
        }
    }

    private func stopVirtualMicrophoneBridge(status: String) {
        routingStatus = status
        for index in streams.indices where streams[index].direction == .recording && !streams[index].isVirtualStream {
            streams[index].routingStatus = status
        }
        Task {
            await VirtualMicrophoneRoutingService.shared.stop()
        }
    }

    private func configureVirtualMicrophoneBridge(
        inputSources: [AudioDevice],
        playbackSources: [AppAudioStream]
    ) {
        guard setupState.virtualCableInputID != nil else {
            Task {
                await VirtualMicrophoneRoutingService.shared.stop()
            }
            return
        }

        guard !inputSources.isEmpty || !playbackSources.isEmpty else {
            routingStatus = "Virtual microphone is active, but no sources are selected"
            return
        }

        Task {
            do {
                let summary = try await VirtualMicrophoneRoutingService.shared.route(
                    inputDevices: inputSources,
                    playbackStreams: playbackSources
                )
                routingStatus = summary
                for index in streams.indices where streams[index].direction == .recording && !streams[index].isVirtualStream {
                    streams[index].requestedDeviceID = setupState.virtualCableInputID
                    streams[index].routeSelectionID = streams[index].routeSelectionID ?? preferredRouteSelectionID(for: streams[index])
                    streams[index].routingStatus = summary
                }
            } catch {
                routingStatus = error.localizedDescription
                for index in streams.indices where streams[index].direction == .recording && !streams[index].isVirtualStream {
                    streams[index].routingStatus = error.localizedDescription
                }
            }
        }
    }

    private func updateRoutingReadinessStatus(hasOutput: Bool, hasInput: Bool, isOutputDefault: Bool) {
        guard routeRequests.isEmpty else {
            return
        }

        if hasOutput && hasInput && isOutputDefault {
            routingStatus = "Virtual cable ready; per-app playback routing is available"
        } else if hasOutput && hasInput {
            routingStatus = "Virtual cable installed; set system output to \(SetupState.virtualCableName) for per-app routing"
        } else if hasOutput || hasInput {
            routingStatus = "Virtual cable partially visible; reinstall latest bundled driver if routing is unstable"
        } else {
            routingStatus = "Virtual cable not installed"
        }
    }

    func installVirtualCable() {
        setupState.isInstalling = true
        setupState.installStatus = "Installing latest bundled virtual cable driver..."

        let installer = driverInstaller
        Task.detached { [weak self] in
            let result = await installer.installBundledDriver()
            await MainActor.run {
                guard let self else { return }
                self.setupState.isInstalling = false
                self.setupState.installStatus = result.message
                self.setupState.diagnostics = self.setupState.diagnostics.map { item in
                    guard item.id == "installer" else { return item }
                    return SetupDiagnosticItem(
                        id: item.id,
                        title: item.title,
                        detail: result.message,
                        state: result.success ? .ready : .blocked
                    )
                }
                self.refreshDevices()
            }
        }
    }

    func uninstallVirtualCable() {
        setupState.isInstalling = true
        setupState.installStatus = "Removing virtual cable driver..."

        let installer = driverInstaller
        Task.detached { [weak self] in
            let result = await installer.uninstallDriver()
            await MainActor.run {
                guard let self else { return }
                self.setupState.isInstalling = false
                self.setupState.installStatus = result.message
                self.refreshDevices()
            }
        }
    }

    func makeVirtualCableDefault() {
        var didChange = false

        if let outputID = setupState.virtualCableOutputID,
           let outputDevice = outputDevices.first(where: { $0.id == outputID }),
           let coreAudioObjectID = outputDevice.coreAudioObjectID {
            didChange = deviceProvider.setDefaultDevice(coreAudioObjectID, direction: .output) || didChange
        }

        if let inputID = setupState.virtualCableInputID,
           let inputDevice = inputDevices.first(where: { $0.id == inputID }),
           let coreAudioObjectID = inputDevice.coreAudioObjectID {
            didChange = deviceProvider.setDefaultDevice(coreAudioObjectID, direction: .input) || didChange
        }

        if didChange {
            refreshDevices()
        } else {
            setupState.defaultDeviceStatus = "Unable to set virtual cable as default through Core Audio"
        }
    }

    func probeVirtualCableIO() {
        guard let outputID = setupState.virtualCableOutputID,
              let outputDevice = outputDevices.first(where: { $0.id == outputID }),
              let coreAudioObjectID = outputDevice.coreAudioObjectID else {
            setupState.defaultDeviceStatus = "Virtual cable output is not available for IO probe"
            return
        }

        setupState.defaultDeviceStatus = "Starting virtual cable IO probe..."
        Task {
            let status = await deviceProvider.probeDeviceIO(deviceID: coreAudioObjectID)
            NSLog("Xavucontrol virtual cable IO probe status=%d objectID=%u", status, coreAudioObjectID)
            setupState.defaultDeviceStatus = status == noErr
                ? "Virtual cable IO probe completed"
                : "Virtual cable IO probe failed with status \(status)"
            refreshSetupDiagnostics()
        }
    }

    private func makeProfiles(outputDevices: [AudioDevice], inputDevices: [AudioDevice]) -> [AudioProfile] {
        let allDevices = outputDevices + inputDevices
        return allDevices.map { device in
            AudioProfile(
                id: "\(device.id)-profile",
                deviceName: device.name,
                selectedProfile: "Core Audio Device",
                availableProfiles: ["Core Audio Device"]
            )
        }
    }

    private func upsertRouteRequest(_ routeRequest: AudioRouteRequest) {
        if let index = routeRequests.firstIndex(where: { $0.streamID == routeRequest.streamID }) {
            routeRequests[index] = routeRequest
        } else {
            routeRequests.append(routeRequest)
        }
    }

    private func updateDevice(deviceID: AudioDevice.ID, kind: DeviceKind, update: (inout AudioDevice) -> Void) {
        switch kind {
        case .output:
            guard let index = outputDevices.firstIndex(where: { $0.id == deviceID }) else { return }
            update(&outputDevices[index])
        case .input:
            guard let index = inputDevices.firstIndex(where: { $0.id == deviceID }) else { return }
            update(&inputDevices[index])
        }
    }

    private func device(kind: DeviceKind, id: AudioDevice.ID) -> AudioDevice? {
        switch kind {
        case .output:
            return outputDevices.first { $0.id == id }
        case .input:
            return inputDevices.first { $0.id == id }
        }
    }
}
