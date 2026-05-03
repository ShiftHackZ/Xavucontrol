import AudioToolbox
import CoreAudio
import Foundation

nonisolated(unsafe) private let xavucontrolVirtualCableDeviceUID = "org.moroz.xavucontrol.virtualcable.device"

struct ProcessTapRouteError: Error, LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

actor ProcessTapRoutingService {
    static let shared = ProcessTapRoutingService()

    private static let virtualCableDeviceUID = xavucontrolVirtualCableDeviceUID

    private var sessions: [String: ProcessTapRouteSession] = [:]

    func route(stream: AppAudioStream, to targetDevice: AudioDevice) async throws -> String {
        try await route(stream: stream, to: targetDevice, requireAudibleSignal: false)
    }

    func routeConfirmed(stream: AppAudioStream, to targetDevice: AudioDevice, timeout: TimeInterval = 1.5) async throws -> String {
        try await route(stream: stream, to: targetDevice, requireAudibleSignal: true, timeout: timeout)
    }

    private func route(
        stream: AppAudioStream,
        to targetDevice: AudioDevice,
        requireAudibleSignal: Bool,
        timeout: TimeInterval = 1.5
    ) async throws -> String {
        guard stream.direction == .playback else {
            throw ProcessTapRouteError(message: "Process tap routing is available for playback streams only")
        }

        guard let processObjectID = ProcessTapRoutingService.processObjectID(from: stream.id) else {
            throw ProcessTapRouteError(message: "Unable to read Core Audio process object ID from stream")
        }
        let processObjectIDs = ProcessTapRoutingService.relatedOutputProcessObjectIDs(for: processObjectID)

        guard let targetDeviceObjectID = targetDevice.coreAudioObjectID else {
            throw ProcessTapRouteError(message: "Target device has no Core Audio object ID")
        }

        let sourceDeviceUID = ProcessTapRoutingService.sourceDeviceUID(
            processObjectID: processObjectID,
            assignedDeviceID: stream.assignedDeviceID
        )

        if let existingSession = sessions[stream.id] {
            existingSession.stop()
            sessions[stream.id] = nil
        }

        let session = ProcessTapRouteSession(
            streamID: stream.id,
            processObjectIDs: processObjectIDs,
            appName: stream.appName,
            sourceDeviceUID: sourceDeviceUID,
            targetDeviceObjectID: targetDeviceObjectID,
            targetDeviceName: targetDevice.name,
            initialVolume: stream.volume,
            initiallyMuted: stream.isMuted
        )
        try session.start()
        if requireAudibleSignal {
            do {
                try await session.waitForAudibleSignal(timeout: timeout)
            } catch {
                session.stop()
                throw error
            }
        }
        sessions[stream.id] = session

        return "Process tap route active: \(stream.appName) -> \(targetDevice.name) from \(sourceDeviceUID) using \(processObjectIDs.count) process tap candidate(s)"
    }

    func stop(streamID: String) {
        sessions[streamID]?.stop()
        sessions[streamID] = nil
    }

    func stopAll() {
        sessions.values.forEach { $0.stop() }
        sessions.removeAll()
    }

    func hasActiveRoutes() -> Bool {
        !sessions.isEmpty
    }

    func setStreamVolume(streamID: String, volume: Double) -> Bool {
        guard let session = sessions[streamID] else {
            return false
        }

        session.setVolume(volume)
        return true
    }

    func setStreamMuted(streamID: String, isMuted: Bool) -> Bool {
        guard let session = sessions[streamID] else {
            return false
        }

        session.setMuted(isMuted)
        return true
    }

    func probeGlobalTap(sourceDeviceUID: String, timeout: TimeInterval = 1.0) async -> String {
        let probe = ProcessTapProbeSession(sourceDeviceUID: sourceDeviceUID)
        do {
            try probe.start()
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            let summary = probe.summary
            probe.stop()
            return summary
        } catch {
            probe.stop()
            return "Global tap probe failed: \(error.localizedDescription)"
        }
    }

    static func processObjectID(from streamID: String) -> AudioObjectID? {
        let prefix = "coreaudio-process-"
        guard streamID.hasPrefix(prefix) else {
            return nil
        }

        let remainder = streamID.dropFirst(prefix.count)
        guard let objectIDText = remainder.split(separator: "-").first,
              let objectID = UInt32(objectIDText) else {
            return nil
        }

        return AudioObjectID(objectID)
    }

    static func relatedOutputProcessObjectIDs(for processObjectID: AudioObjectID) -> [AudioObjectID] {
        let selectedBundleID = processBundleID(processObjectID: processObjectID)
        let candidates = allProcessObjectIDs()
            .filter { isRunningOutput(processObjectID: $0) }
            .filter { candidateID in
                guard candidateID != processObjectID else {
                    return true
                }
                guard let selectedBundleID,
                      let candidateBundleID = processBundleID(processObjectID: candidateID) else {
                    return false
                }
                return bundleIDsAreRelated(selectedBundleID, candidateBundleID)
            }

        var uniqueIDs = [processObjectID]
        for candidateID in candidates where !uniqueIDs.contains(candidateID) {
            uniqueIDs.append(candidateID)
        }
        return uniqueIDs
    }

    static func sourceDeviceUID(processObjectID: AudioObjectID?, assignedDeviceID: AudioDevice.ID?) -> String {
        virtualCableDeviceUID
    }

    static func diagnosticHardwareSourceDeviceUID(processObjectID: AudioObjectID?, assignedDeviceID: AudioDevice.ID?) -> String {
        if let processObjectID,
           let processDeviceUID = currentOutputDeviceUID(processObjectID: processObjectID),
           processDeviceUID != virtualCableDeviceUID {
            return processDeviceUID
        }

        if let defaultOutputUID = defaultOutputDeviceUID(),
           defaultOutputUID != virtualCableDeviceUID {
            return defaultOutputUID
        }

        let outputPrefix = "output-"
        guard let assignedDeviceID,
              assignedDeviceID.hasPrefix(outputPrefix) else {
            return virtualCableDeviceUID
        }

        return String(assignedDeviceID.dropFirst(outputPrefix.count))
    }

    private static func currentOutputDeviceUID(processObjectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyDevices,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(processObjectID, &address, 0, nil, &dataSize) == noErr,
              dataSize >= MemoryLayout<AudioObjectID>.size else {
            return nil
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = Array(repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        guard AudioObjectGetPropertyData(processObjectID, &address, 0, nil, &dataSize, &deviceIDs) == noErr else {
            return nil
        }

        let deviceUIDs = deviceIDs.compactMap { deviceID in
            deviceID == kAudioObjectUnknown ? nil : deviceUID(deviceID: deviceID)
        }
        return deviceUIDs.first { $0 != virtualCableDeviceUID } ?? deviceUIDs.first
    }

    private static func defaultOutputDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else {
            return nil
        }
        return deviceUID(deviceID: deviceID)
    }

    private static func deviceUID(deviceID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var value: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, pointer)
        }
        guard status == noErr else {
            return nil
        }
        return value as String
    }

    private static func allProcessObjectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var processObjectIDs = Array(repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &processObjectIDs) == noErr else {
            return []
        }
        return processObjectIDs.filter { $0 != kAudioObjectUnknown }
    }

    private static func isRunningOutput(processObjectID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(processObjectID, &address) else {
            return false
        }

        var isRunning: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(processObjectID, &address, 0, nil, &dataSize, &isRunning)
        return status == noErr && isRunning != 0
    }

    private static func processBundleID(processObjectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(processObjectID, &address) else {
            return nil
        }

        var value: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(processObjectID, &address, 0, nil, &dataSize, pointer)
        }
        guard status == noErr else {
            return nil
        }

        let bundleID = value as String
        return bundleID.isEmpty ? nil : bundleID
    }

    private static func bundleIDsAreRelated(_ lhs: String, _ rhs: String) -> Bool {
        let lhs = lhs.lowercased()
        let rhs = rhs.lowercased()
        return lhs == rhs
            || lhs.hasPrefix(rhs + ".")
            || rhs.hasPrefix(lhs + ".")
            || normalizedAppBundleID(lhs) == normalizedAppBundleID(rhs)
    }

    private static func normalizedAppBundleID(_ bundleID: String) -> String {
        var components = bundleID.split(separator: ".").map(String.init)
        let helperSuffixes: Set<String> = [
            "helper",
            "renderer",
            "gpu",
            "plugin",
            "extension",
            "loginhelper",
            "alerts",
            "watcher"
        ]

        while let last = components.last?.lowercased(),
              helperSuffixes.contains(last) || last.hasPrefix("helper") {
            components.removeLast()
        }

        return components.joined(separator: ".")
    }
}

private struct VirtualCableOutputControlState {
    let volume: Float32
    let isMuted: Bool

    static func current(deviceUID: String) -> VirtualCableOutputControlState? {
        guard let deviceID = deviceID(forUID: deviceUID) else {
            return nil
        }

        let volume = readFloat32(
            objectID: deviceID,
            selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            scope: kAudioDevicePropertyScopeOutput,
            element: kAudioObjectPropertyElementMain
        ) ?? readFloat32(
            objectID: deviceID,
            selector: kAudioDevicePropertyVolumeScalar,
            scope: kAudioDevicePropertyScopeOutput,
            element: kAudioObjectPropertyElementMain
        ) ?? 1

        let muted = readUInt32(
            objectID: deviceID,
            selector: kAudioDevicePropertyMute,
            scope: kAudioDevicePropertyScopeOutput,
            element: kAudioObjectPropertyElementMain
        ).map { $0 != 0 } ?? false

        return VirtualCableOutputControlState(
            volume: max(0, min(1, volume)),
            isMuted: muted
        )
    }

    private static func deviceID(forUID uid: String) -> AudioObjectID? {
        allDeviceIDs().first { deviceID in
            readDeviceUID(deviceID: deviceID) == uid
        }
    }

    private static func allDeviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = Array(repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs) == noErr else {
            return []
        }
        return deviceIDs.filter { $0 != kAudioObjectUnknown }
    }

    private static func readDeviceUID(deviceID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var value: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, pointer)
        }
        guard status == noErr else {
            return nil
        }
        return value as String
    }

    private static func readFloat32(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Float32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )

        guard AudioObjectHasProperty(objectID, &address) else {
            return nil
        }

        var value = Float32.zero
        var dataSize = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value)
        guard status == noErr else {
            return nil
        }
        return value
    }

    private static func readUInt32(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )

        guard AudioObjectHasProperty(objectID, &address) else {
            return nil
        }

        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value)
        guard status == noErr else {
            return nil
        }
        return value
    }
}

private nonisolated final class ProcessTapProbeSession {
    private let sourceDeviceUID: String
    private var tapFormat = AudioStreamBasicDescription()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var callbackCount: UInt64 = 0
    private var emptyCallbackCount: UInt64 = 0
    private var capturedBytes: UInt64 = 0
    private var lastInputBufferCount: UInt32 = 0
    private var lastInputByteSize: UInt32 = 0
    private var peakLevel: Float32 = 0
    private var rmsLevel: Float32 = 0
    private var didStart = false

    init(sourceDeviceUID: String) {
        self.sourceDeviceUID = sourceDeviceUID
    }

    var summary: String {
        let text = String(
            format: "Global tap probe sourceUID=%@ callbacks=%llu empty=%llu lastBuffers=%u lastBytes=%u captured=%llu peak=%.5f rms=%.5f tapFormat=%@",
            sourceDeviceUID,
            callbackCount,
            emptyCallbackCount,
            lastInputBufferCount,
            lastInputByteSize,
            capturedBytes,
            peakLevel,
            rmsLevel,
            formatSummary(tapFormat)
        )
        NSLog("Xavucontrol %@", text)
        return text
    }

    deinit {
        stop()
    }

    func start() throws {
        guard !didStart else {
            return
        }

        guard #available(macOS 14.2, *) else {
            throw ProcessTapRouteError(message: "Process taps require macOS 14.2 or newer")
        }

        let tapDescription = CATapDescription(
            excludingProcesses: [],
            deviceUID: sourceDeviceUID,
            stream: 0
        )
        tapDescription.name = "Xavucontrol global tap probe"
        tapDescription.isPrivate = true
        tapDescription.isExclusive = true
        tapDescription.muteBehavior = CATapMuteBehavior.unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(tapDescription, &newTapID), "Create global tap probe")
        tapID = newTapID

        let tapUID = try readTapUID(tapID: tapID)
        aggregateDeviceID = try createAggregateDevice(tapUID: tapUID)
        tapFormat = try readTapFormat(tapID: tapID)

        var createdIOProcID: AudioDeviceIOProcID?
        let context = Unmanaged.passUnretained(self).toOpaque()
        try check(AudioDeviceCreateIOProcID(aggregateDeviceID, globalTapProbeInputProc, context, &createdIOProcID), "Create global tap probe IOProc")
        guard let createdIOProcID else {
            throw ProcessTapRouteError(message: "Core Audio did not return a global tap probe IOProc ID")
        }

        ioProcID = createdIOProcID
        try check(AudioDeviceStart(aggregateDeviceID, createdIOProcID), "Start global tap probe IOProc")
        didStart = true
    }

    func stop() {
        if aggregateDeviceID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateDeviceID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
                self.ioProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }

        if #available(macOS 14.2, *), tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }

        didStart = false
    }

    fileprivate func handleTapInput(_ inputData: UnsafePointer<AudioBufferList>?) {
        callbackCount += 1
        guard let inputData else {
            emptyCallbackCount += 1
            lastInputBufferCount = 0
            lastInputByteSize = 0
            return
        }

        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        lastInputBufferCount = UInt32(buffers.count)
        lastInputByteSize = buffers.reduce(UInt32(0)) { partial, buffer in
            partial + buffer.mDataByteSize
        }
        capturedBytes += UInt64(lastInputByteSize)
        updateLevels(buffers: buffers)
    }

    private func updateLevels(buffers: UnsafeMutableAudioBufferListPointer) {
        var peak = Float32.zero
        var sumSquares = Float64.zero
        var sampleCount = 0

        for buffer in buffers {
            guard let data = buffer.mData, buffer.mDataByteSize > 0 else {
                continue
            }

            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size
            let samples = data.assumingMemoryBound(to: Float32.self)
            for index in 0..<count {
                let sample = samples[index]
                peak = max(peak, abs(sample))
                sumSquares += Double(sample * sample)
            }
            sampleCount += count
        }

        guard sampleCount > 0 else {
            peakLevel = 0
            rmsLevel = 0
            return
        }

        peakLevel = peak
        rmsLevel = Float32(sqrt(sumSquares / Double(sampleCount)))
    }

    private func createAggregateDevice(tapUID: String) throws -> AudioObjectID {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Xavucontrol Global Tap Probe",
            kAudioAggregateDeviceUIDKey: "org.moroz.xavucontrol.global-tap-probe.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ],
            kAudioAggregateDeviceTapAutoStartKey: false
        ]

        var deviceID = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID), "Create global tap probe aggregate device")
        return deviceID
    }

    private func readTapUID(tapID: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var value: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        try check(withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &dataSize, pointer)
        }, "Read global tap probe UID")
        return value as String
    }

    private func readTapFormat(tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var format = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &dataSize, &format), "Read global tap probe format")
        return format
    }

    private func formatSummary(_ format: AudioStreamBasicDescription) -> String {
        let layout = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0 ? "planar" : "interleaved"
        return "rate=\(format.mSampleRate), flags=\(format.mFormatFlags), bytesPerFrame=\(format.mBytesPerFrame), channels=\(format.mChannelsPerFrame), \(layout)"
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw ProcessTapRouteError(message: "\(operation) failed: \(describe(status: status))")
        }
    }

    private func describe(status: OSStatus) -> String {
        let code = UInt32(bitPattern: status)
        let bytes = [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff),
            UInt8(code & 0xff)
        ]

        let isPrintable = bytes.allSatisfy { byte in
            byte >= 32 && byte <= 126
        }

        if isPrintable, let fourCC = String(bytes: bytes, encoding: .macOSRoman) {
            return "\(status) ('\(fourCC)')"
        }

        return "\(status)"
    }
}

private nonisolated final class ProcessTapRouteSession {
    private let streamID: String
    private let processObjectIDs: [AudioObjectID]
    private let appName: String
    private let sourceDeviceUID: String
    private let targetDeviceObjectID: AudioObjectID
    private let targetDeviceName: String
    private let ringBuffer = ByteRingBuffer(capacity: 48_000 * 4 * 4)
    private var tapFormat = AudioStreamBasicDescription()
    private var outputFormat = ProcessTapRouteSession.outputFormat(sampleRate: 48_000)

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var queue: AudioQueueRef?
    private var queueBuffers: [AudioQueueBufferRef] = []
    private var diagnosticsTimer: DispatchSourceTimer?
    private var requestedOutputDeviceUID = ""
    private var actualOutputDeviceUID = ""
    private var capturedBytes: UInt64 = 0
    private var playedBytes: UInt64 = 0
    private var underflowCount: UInt64 = 0
    private var callbackCount: UInt64 = 0
    private var emptyCallbackCount: UInt64 = 0
    private var lastInputBufferCount: UInt32 = 0
    private var lastInputByteSize: UInt32 = 0
    private var peakLevel: Float32 = 0
    private var rmsLevel: Float32 = 0
    private var didStart = false
    private let controlLock = NSLock()
    private var volumeGain: Float32 = 1
    private var muted = false
    private var virtualCableVolumeGain: Float32 = 1
    private var virtualCableMuted = false
    private var virtualCableControlTimer: DispatchSourceTimer?

    init(
        streamID: String,
        processObjectIDs: [AudioObjectID],
        appName: String,
        sourceDeviceUID: String,
        targetDeviceObjectID: AudioObjectID,
        targetDeviceName: String,
        initialVolume: Double,
        initiallyMuted: Bool
    ) {
        self.streamID = streamID
        self.processObjectIDs = processObjectIDs
        self.appName = appName
        self.sourceDeviceUID = sourceDeviceUID
        self.targetDeviceObjectID = targetDeviceObjectID
        self.targetDeviceName = targetDeviceName
        self.volumeGain = Float32(max(0, min(1, initialVolume)))
        self.muted = initiallyMuted
    }

    deinit {
        stop()
    }

    func start() throws {
        guard !didStart else {
            return
        }

        guard #available(macOS 14.2, *) else {
            throw ProcessTapRouteError(message: "Process taps require macOS 14.2 or newer")
        }

        let tapDescription = CATapDescription(
            processes: processObjectIDs,
            deviceUID: sourceDeviceUID,
            stream: 0
        )
        tapDescription.name = "Xavucontrol tap - \(appName)"
        tapDescription.isPrivate = true
        tapDescription.isExclusive = false
        tapDescription.muteBehavior = CATapMuteBehavior.mutedWhenTapped

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(tapDescription, &newTapID), "Create process tap")
        tapID = newTapID

        let tapUID = try readTapUID(tapID: tapID)
        aggregateDeviceID = try createAggregateDevice(tapUID: tapUID)

        tapFormat = try readTapFormat(tapID: tapID)
        if tapFormat.mSampleRate == 0 {
            tapFormat = ProcessTapRouteSession.outputFormat(sampleRate: 48_000)
        }
        outputFormat = ProcessTapRouteSession.outputFormat(sampleRate: tapFormat.mSampleRate)

        refreshVirtualCableControlState()
        try startOutputQueue(format: outputFormat)
        try startTapInput()
        startVirtualCableControlMonitorIfNeeded()
        startDiagnosticsTimer()
        didStart = true
    }

    func waitForAudibleSignal(timeout: TimeInterval) async throws {
        let startedAt = Date()
        while Date().timeIntervalSince(startedAt) < timeout {
            if capturedBytes > 0 {
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        throw ProcessTapRouteError(
            message: "Process tap produced no PCM for \(appName) after \(String(format: "%.1f", timeout))s"
        )
    }

    func setVolume(_ volume: Double) {
        controlLock.lock()
        volumeGain = Float32(max(0, min(1, volume)))
        controlLock.unlock()
    }

    func setMuted(_ isMuted: Bool) {
        controlLock.lock()
        muted = isMuted
        controlLock.unlock()
    }

    func stop() {
        diagnosticsTimer?.cancel()
        diagnosticsTimer = nil
        virtualCableControlTimer?.cancel()
        virtualCableControlTimer = nil

        if let queue {
            AudioQueueStop(queue, true)
            AudioQueueDispose(queue, true)
            self.queue = nil
        }
        queueBuffers.removeAll()

        if aggregateDeviceID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateDeviceID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
                self.ioProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }

        if #available(macOS 14.2, *), tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }

        didStart = false
    }

    private func startTapInput() throws {
        var createdIOProcID: AudioDeviceIOProcID?
        let context = Unmanaged.passUnretained(self).toOpaque()
        try check(AudioDeviceCreateIOProcID(aggregateDeviceID, processTapInputProc, context, &createdIOProcID), "Create tap IOProc")
        guard let createdIOProcID else {
            throw ProcessTapRouteError(message: "Core Audio did not return an IOProc ID")
        }

        ioProcID = createdIOProcID
        try check(AudioDeviceStart(aggregateDeviceID, createdIOProcID), "Start tap IOProc")
    }

    private func startOutputQueue(format: AudioStreamBasicDescription) throws {
        var outputQueue: AudioQueueRef?
        let context = Unmanaged.passUnretained(self).toOpaque()
        var mutableFormat = format

        try check(AudioQueueNewOutput(&mutableFormat, processTapOutputProc, context, nil, nil, 0, &outputQueue), "Create output AudioQueue")
        guard let outputQueue else {
            throw ProcessTapRouteError(message: "AudioQueue output could not be created")
        }

        let targetUID = try readDeviceUID(deviceID: targetDeviceObjectID)
        requestedOutputDeviceUID = targetUID
        var uid = targetUID as CFString
        try check(withUnsafePointer(to: &uid) { pointer in
            AudioQueueSetProperty(
                outputQueue,
                kAudioQueueProperty_CurrentDevice,
                pointer,
                UInt32(MemoryLayout<CFString>.size)
            )
        }, "Set AudioQueue output device")
        actualOutputDeviceUID = readAudioQueueCurrentDevice(outputQueue) ?? "unreadable"
        AudioQueueSetParameter(outputQueue, kAudioQueueParam_Volume, 1.0)

        let bytesPerFrame = max(Int(format.mBytesPerFrame), 8)
        let bufferByteSize = UInt32(bytesPerFrame * 1024)
        for _ in 0..<4 {
            var buffer: AudioQueueBufferRef?
            try check(AudioQueueAllocateBuffer(outputQueue, bufferByteSize, &buffer), "Allocate AudioQueue buffer")
            guard let buffer else { continue }
            queueBuffers.append(buffer)
            fillOutputBuffer(buffer)
            try check(AudioQueueEnqueueBuffer(outputQueue, buffer, 0, nil), "Prime AudioQueue buffer")
        }

        queue = outputQueue
        try check(AudioQueueStart(outputQueue, nil), "Start output AudioQueue")
    }

    fileprivate func handleTapInput(_ inputData: UnsafePointer<AudioBufferList>?) {
        callbackCount += 1
        guard let inputData else {
            emptyCallbackCount += 1
            lastInputBufferCount = 0
            lastInputByteSize = 0
            return
        }

        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        lastInputBufferCount = UInt32(buffers.count)
        lastInputByteSize = buffers.reduce(UInt32(0)) { partial, buffer in
            partial + buffer.mDataByteSize
        }
        if shouldTreatInputAsPlanarFloat(buffers: buffers) {
            writePlanarFloatInput(buffers: buffers)
        } else if let buffer = buffers.first,
                  let data = buffer.mData,
                  buffer.mDataByteSize > 0 {
            let count = Int(buffer.mDataByteSize)
            writeInterleavedFloatInput(data: data, byteCount: count)
        }
    }

    private func writeInterleavedFloatInput(data: UnsafeMutableRawPointer, byteCount: Int) {
        let sampleCount = byteCount / MemoryLayout<Float32>.size
        guard sampleCount > 0 else {
            peakLevel = 0
            rmsLevel = 0
            return
        }

        let gain = currentGain()
        let samples = data.assumingMemoryBound(to: Float32.self)
        var adjusted = Array(repeating: Float32.zero, count: sampleCount)
        var peak = Float32.zero
        var sumSquares = Float64.zero

        for index in 0..<sampleCount {
            let sample = samples[index] * gain
            adjusted[index] = sample
            peak = max(peak, abs(sample))
            sumSquares += Double(sample * sample)
        }

        peakLevel = peak
        rmsLevel = Float32(sqrt(sumSquares / Double(sampleCount)))
        adjusted.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }

            ringBuffer.write(bytes: baseAddress.assumingMemoryBound(to: UInt8.self), count: rawBuffer.count)
            capturedBytes += UInt64(rawBuffer.count)
        }
    }

    private func fillOutputBuffer(_ buffer: AudioQueueBufferRef) {
        let capacity = Int(buffer.pointee.mAudioDataBytesCapacity)
        let written = ringBuffer.read(into: buffer.pointee.mAudioData.assumingMemoryBound(to: UInt8.self), count: capacity)
        playedBytes += UInt64(written)

        if written < capacity {
            underflowCount += 1
            memset(buffer.pointee.mAudioData.advanced(by: written), 0, capacity - written)
        }

        buffer.pointee.mAudioDataByteSize = UInt32(capacity)
    }

    fileprivate func handleOutputBuffer(queue: AudioQueueRef, buffer: AudioQueueBufferRef) {
        fillOutputBuffer(buffer)
        AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    }

    private func shouldTreatInputAsPlanarFloat(buffers: UnsafeMutableAudioBufferListPointer) -> Bool {
        guard buffers.count >= 2 else {
            return false
        }

        let isFloat = (tapFormat.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        return isFloat && isNonInterleaved
    }

    private func writePlanarFloatInput(buffers: UnsafeMutableAudioBufferListPointer) {
        guard buffers.count >= 2,
              let leftData = buffers[0].mData,
              let rightData = buffers[1].mData else {
            return
        }

        let leftFrames = Int(buffers[0].mDataByteSize) / MemoryLayout<Float32>.size
        let rightFrames = Int(buffers[1].mDataByteSize) / MemoryLayout<Float32>.size
        let frameCount = min(leftFrames, rightFrames)
        guard frameCount > 0 else {
            return
        }

        let left = leftData.assumingMemoryBound(to: Float32.self)
        let right = rightData.assumingMemoryBound(to: Float32.self)
        var interleaved = Array(repeating: Float32.zero, count: frameCount * 2)
        var peak = Float32.zero
        var sumSquares = Float64.zero
        let gain = currentGain()
        for frame in 0..<frameCount {
            let leftSample = left[frame] * gain
            let rightSample = right[frame] * gain
            interleaved[frame * 2] = leftSample
            interleaved[frame * 2 + 1] = rightSample
            peak = max(peak, abs(leftSample), abs(rightSample))
            sumSquares += Double(leftSample * leftSample + rightSample * rightSample)
        }
        peakLevel = peak
        rmsLevel = Float32(sqrt(sumSquares / Double(frameCount * 2)))

        interleaved.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }

            ringBuffer.write(bytes: baseAddress.assumingMemoryBound(to: UInt8.self), count: rawBuffer.count)
            capturedBytes += UInt64(rawBuffer.count)
        }
    }

    private func currentGain() -> Float32 {
        controlLock.lock()
        let streamGain = muted ? Float32.zero : volumeGain
        let virtualCableGain = virtualCableMuted ? Float32.zero : virtualCableVolumeGain
        controlLock.unlock()
        return streamGain * virtualCableGain
    }

    private func startVirtualCableControlMonitorIfNeeded() {
        guard sourceDeviceUID == xavucontrolVirtualCableDeviceUID else {
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            self?.refreshVirtualCableControlState()
        }
        virtualCableControlTimer = timer
        timer.resume()
    }

    private func refreshVirtualCableControlState() {
        guard sourceDeviceUID == xavucontrolVirtualCableDeviceUID,
              let state = VirtualCableOutputControlState.current(deviceUID: sourceDeviceUID) else {
            return
        }

        controlLock.lock()
        virtualCableVolumeGain = state.volume
        virtualCableMuted = state.isMuted
        controlLock.unlock()
    }

    private func startDiagnosticsTimer() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 2, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self else {
                return
            }

            NSLog(
                "Xavucontrol process tap route %@ -> %@ sourceUID=%@ callbacks=%llu empty=%llu lastBuffers=%u lastBytes=%u captured=%llu played=%llu buffered=%d underflows=%llu peak=%.5f rms=%.5f requestedUID=%@ actualUID=%@ tapFormat=%@",
                self.appName,
                self.targetDeviceName,
                self.sourceDeviceUID,
                self.callbackCount,
                self.emptyCallbackCount,
                self.lastInputBufferCount,
                self.lastInputByteSize,
                self.capturedBytes,
                self.playedBytes,
                self.ringBuffer.availableBytes,
                self.underflowCount,
                self.peakLevel,
                self.rmsLevel,
                self.requestedOutputDeviceUID,
                self.actualOutputDeviceUID,
                self.formatSummary(self.tapFormat)
            )
        }
        diagnosticsTimer = timer
        timer.resume()
    }

    private func createAggregateDevice(tapUID: String) throws -> AudioObjectID {
        let aggregateUID = "org.moroz.xavucontrol.tap.\(streamID).\(UUID().uuidString)"
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Xavucontrol Tap - \(appName) to \(targetDeviceName)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ],
            kAudioAggregateDeviceTapAutoStartKey: false
        ]

        var deviceID = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID), "Create tap aggregate device")
        return deviceID
    }

    private func readTapUID(tapID: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var value: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        try check(withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &dataSize, pointer)
        }, "Read tap UID")
        return value as String
    }

    private func readTapFormat(tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var format = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &dataSize, &format), "Read tap format")
        return format
    }

    private func readDeviceUID(deviceID: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var value: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        try check(withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, pointer)
        }, "Read target device UID")
        return value as String
    }

    private func updateInterleavedFloatLevels(data: UnsafeMutableRawPointer, byteCount: Int) {
        let sampleCount = byteCount / MemoryLayout<Float32>.size
        guard sampleCount > 0 else {
            peakLevel = 0
            rmsLevel = 0
            return
        }

        let samples = data.assumingMemoryBound(to: Float32.self)
        var peak = Float32.zero
        var sumSquares = Float64.zero
        for index in 0..<sampleCount {
            let sample = samples[index]
            peak = max(peak, abs(sample))
            sumSquares += Double(sample * sample)
        }
        peakLevel = peak
        rmsLevel = Float32(sqrt(sumSquares / Double(sampleCount)))
    }

    private func readAudioQueueCurrentDevice(_ queue: AudioQueueRef) -> String? {
        var dataSize: UInt32 = 0
        guard AudioQueueGetPropertySize(queue, kAudioQueueProperty_CurrentDevice, &dataSize) == noErr,
              dataSize > 0 else {
            return nil
        }

        var value: CFString = "" as CFString
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioQueueGetProperty(queue, kAudioQueueProperty_CurrentDevice, pointer, &dataSize)
        }
        guard status == noErr else {
            return nil
        }

        return value as String
    }

    private static func outputFormat(sampleRate: Float64) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate > 0 ? sampleRate : 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    private func formatSummary(_ format: AudioStreamBasicDescription) -> String {
        let layout = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0 ? "planar" : "interleaved"
        return "rate=\(format.mSampleRate), flags=\(format.mFormatFlags), bytesPerFrame=\(format.mBytesPerFrame), channels=\(format.mChannelsPerFrame), \(layout)"
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw ProcessTapRouteError(message: "\(operation) failed: \(ProcessTapRouteSession.describe(status: status))")
        }
    }

    private static func describe(status: OSStatus) -> String {
        let code = UInt32(bitPattern: status)
        let bytes = [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff),
            UInt8(code & 0xff)
        ]

        let isPrintable = bytes.allSatisfy { byte in
            byte >= 32 && byte <= 126
        }

        if isPrintable, let fourCC = String(bytes: bytes, encoding: .macOSRoman) {
            return "\(status) ('\(fourCC)')"
        }

        return "\(status)"
    }
}

private nonisolated final class ByteRingBuffer {
    private let lock = NSLock()
    private var storage: [UInt8]
    private var readIndex = 0
    private var writeIndex = 0
    private var available = 0

    init(capacity: Int) {
        storage = Array(repeating: 0, count: max(capacity, 1))
    }

    var availableBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return available
    }

    func write(bytes: UnsafePointer<UInt8>, count: Int) {
        guard count > 0 else {
            return
        }

        lock.lock()
        defer { lock.unlock() }

        for offset in 0..<count {
            storage[writeIndex] = bytes[offset]
            writeIndex = (writeIndex + 1) % storage.count

            if available == storage.count {
                readIndex = (readIndex + 1) % storage.count
            } else {
                available += 1
            }
        }
    }

    func read(into destination: UnsafeMutablePointer<UInt8>, count: Int) -> Int {
        guard count > 0 else {
            return 0
        }

        lock.lock()
        defer { lock.unlock() }

        let bytesToRead = min(count, available)
        for offset in 0..<bytesToRead {
            destination[offset] = storage[readIndex]
            readIndex = (readIndex + 1) % storage.count
        }
        available -= bytesToRead
        return bytesToRead
    }
}

nonisolated private let processTapInputProc: AudioDeviceIOProc = { _, _, inputData, _, _, _, clientData in
    guard let clientData else {
        return noErr
    }

    let session = Unmanaged<ProcessTapRouteSession>.fromOpaque(clientData).takeUnretainedValue()
    session.handleTapInput(inputData)
    return noErr
}

nonisolated private let globalTapProbeInputProc: AudioDeviceIOProc = { _, _, inputData, _, _, _, clientData in
    guard let clientData else {
        return noErr
    }

    let session = Unmanaged<ProcessTapProbeSession>.fromOpaque(clientData).takeUnretainedValue()
    session.handleTapInput(inputData)
    return noErr
}

nonisolated private let processTapOutputProc: AudioQueueOutputCallback = { clientData, queue, buffer in
    guard let clientData else {
        return
    }

    let session = Unmanaged<ProcessTapRouteSession>.fromOpaque(clientData).takeUnretainedValue()
    session.handleOutputBuffer(queue: queue, buffer: buffer)
}
