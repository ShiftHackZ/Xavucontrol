import CoreAudio
import AudioToolbox
import Darwin
import Foundation

enum AudioDeviceDirection {
    case output
    case input

    var scope: AudioObjectPropertyScope {
        switch self {
        case .output: kAudioDevicePropertyScopeOutput
        case .input: kAudioDevicePropertyScopeInput
        }
    }

    var defaultDeviceSelector: AudioObjectPropertySelector {
        switch self {
        case .output: kAudioHardwarePropertyDefaultOutputDevice
        case .input: kAudioHardwarePropertyDefaultInputDevice
        }
    }

    var idPrefix: String {
        switch self {
        case .output: "coreaudio-output"
        case .input: "coreaudio-input"
        }
    }

    var fallbackIconName: String {
        switch self {
        case .output: "speaker.wave.2.fill"
        case .input: "mic.fill"
        }
    }
}

struct CoreAudioDeviceProvider {
    private enum VirtualCableProperty {
        static let diagnosticsVersion = AudioObjectPropertySelector(0x70767673) // pvvs
        static let capturedFrames = AudioObjectPropertySelector(0x70766672) // pvfr
        static let ioCycles = AudioObjectPropertySelector(0x70766379) // pvcy
        static let lastPeak = AudioObjectPropertySelector(0x7076706B) // pvpk
        static let lastRMS = AudioObjectPropertySelector(0x7076726D) // pvrm
    }

    func loadDevices(direction: AudioDeviceDirection) -> [AudioDevice] {
        let defaultDeviceID = defaultDevice(direction: direction)

        return allDeviceIDs()
            .filter { hasStreams(deviceID: $0, direction: direction) }
            .map { deviceID in
                makeDevice(
                    deviceID: deviceID,
                    direction: direction,
                    isDefault: deviceID == defaultDeviceID
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDefault != rhs.isDefault {
                    return lhs.isDefault
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    func setVolume(_ volume: Double, deviceID: AudioObjectID, direction: AudioDeviceDirection) {
        guard supportsVolume(deviceID: deviceID, direction: direction) else {
            return
        }

        var scalar = Float32(max(0, min(1, volume)))
        let scalarSize = UInt32(MemoryLayout<Float32>.size)

        if settableSet(
            selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            scope: direction.scope,
            element: kAudioObjectPropertyElementMain,
            objectID: deviceID,
            dataSize: scalarSize,
            data: &scalar
        ) {
            return
        }

        for channel in channelElements(deviceID: deviceID, direction: direction) {
            var channelScalar = scalar
            _ = settableSet(
                selector: kAudioDevicePropertyVolumeScalar,
                scope: direction.scope,
                element: channel,
                objectID: deviceID,
                dataSize: scalarSize,
                data: &channelScalar
            )
        }
    }

    func setMuted(_ isMuted: Bool, deviceID: AudioObjectID, direction: AudioDeviceDirection) {
        guard supportsMute(deviceID: deviceID, direction: direction) else {
            return
        }

        var muteValue: UInt32 = isMuted ? 1 : 0
        _ = settableSet(
            selector: kAudioDevicePropertyMute,
            scope: direction.scope,
            element: kAudioObjectPropertyElementMain,
            objectID: deviceID,
            dataSize: UInt32(MemoryLayout<UInt32>.size),
            data: &muteValue
        )
    }

    func setDefaultDevice(_ deviceID: AudioObjectID, direction: AudioDeviceDirection) -> Bool {
        var targetDeviceID = deviceID
        var address = AudioObjectPropertyAddress(
            mSelector: direction.defaultDeviceSelector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var isSettable = DarwinBoolean(false)
        guard AudioObjectHasProperty(AudioObjectID(kAudioObjectSystemObject), &address),
              AudioObjectIsPropertySettable(AudioObjectID(kAudioObjectSystemObject), &address, &isSettable) == noErr,
              isSettable.boolValue else {
            return false
        }

        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioObjectID>.size),
            &targetDeviceID
        ) == noErr
    }

    func probeDeviceIO(deviceID: AudioObjectID, duration: TimeInterval = 1.0) async -> OSStatus {
        var ioProcID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(
            &ioProcID,
            deviceID,
            DispatchQueue(label: "org.moroz.xavucontrol.virtual-cable-probe")
        ) { _, _, _, outputData, _ in
            for buffer in UnsafeMutableAudioBufferListPointer(outputData) {
                guard let data = buffer.mData else {
                    continue
                }
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }

        guard createStatus == noErr, let ioProcID else {
            return createStatus
        }

        let startStatus = AudioDeviceStart(deviceID, ioProcID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(deviceID, ioProcID)
            return startStatus
        }

        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        let stopStatus = AudioDeviceStop(deviceID, ioProcID)
        AudioDeviceDestroyIOProcID(deviceID, ioProcID)
        return stopStatus == noErr ? startStatus : stopStatus
    }

    func virtualCableDiagnostics(deviceID: AudioObjectID) -> VirtualCableDriverDiagnostics? {
        if let sharedDiagnostics = sharedVirtualCableDiagnostics() {
            return sharedDiagnostics
        }

        let version = readUInt32Unchecked(
            deviceID: deviceID,
            selector: VirtualCableProperty.diagnosticsVersion,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain
        )
        let frames = readUInt64Unchecked(
            deviceID: deviceID,
            selector: VirtualCableProperty.capturedFrames,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain
        )
        let cycles = readUInt64Unchecked(
            deviceID: deviceID,
            selector: VirtualCableProperty.ioCycles,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain
        )
        let peak = readFloat32Unchecked(
            deviceID: deviceID,
            selector: VirtualCableProperty.lastPeak,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain
        )
        let rms = readFloat32Unchecked(
            deviceID: deviceID,
            selector: VirtualCableProperty.lastRMS,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain
        )

        let readStatus = VirtualCableDriverDiagnostics.ReadStatus(
            version: version.status,
            frames: frames.status,
            cycles: cycles.status,
            peak: peak.status,
            rms: rms.status
        )

        return VirtualCableDriverDiagnostics(
            version: version.value,
            capturedFrames: frames.value,
            ioCycles: cycles.value,
            peak: peak.value,
            rms: rms.value,
            startCount: 0,
            stopCount: 0,
            willMixOutputCount: 0,
            willWriteMixCount: 0,
            doMixOutputCount: 0,
            doWriteMixCount: 0,
            lastOperation: 0,
            willThreadCount: 0,
            willCycleCount: 0,
            beginThreadCount: 0,
            beginCycleCount: 0,
            beginWriteMixCount: 0,
            endThreadCount: 0,
            endCycleCount: 0,
            endWriteMixCount: 0,
            lastBeginOperation: 0,
            lastEndOperation: 0,
            readStatus: readStatus
        )
    }
}

struct VirtualCableDriverDiagnostics: Hashable {
    struct ReadStatus: Hashable {
        var version: OSStatus
        var frames: OSStatus
        var cycles: OSStatus
        var peak: OSStatus
        var rms: OSStatus

        static let ok = ReadStatus(version: noErr, frames: noErr, cycles: noErr, peak: noErr, rms: noErr)

        var isOK: Bool {
            version == noErr && frames == noErr && cycles == noErr && peak == noErr && rms == noErr
        }

        var summary: String {
            "status version \(version), frames \(frames), cycles \(cycles), peak \(peak), rms \(rms)"
        }
    }

    var version: UInt32
    var capturedFrames: UInt64
    var ioCycles: UInt64
    var peak: Float32
    var rms: Float32
    var startCount: UInt64
    var stopCount: UInt64
    var willMixOutputCount: UInt64
    var willWriteMixCount: UInt64
    var doMixOutputCount: UInt64
    var doWriteMixCount: UInt64
    var lastOperation: UInt32
    var willThreadCount: UInt64
    var willCycleCount: UInt64
    var beginThreadCount: UInt64
    var beginCycleCount: UInt64
    var beginWriteMixCount: UInt64
    var endThreadCount: UInt64
    var endCycleCount: UInt64
    var endWriteMixCount: UInt64
    var lastBeginOperation: UInt32
    var lastEndOperation: UInt32
    var readStatus: ReadStatus
}

private extension CoreAudioDeviceProvider {
    func sharedVirtualCableDiagnostics() -> VirtualCableDriverDiagnostics? {
        let sharedMemoryPath = "/tmp/xavucontrol_virtual_cable_diag_v1"
        let sharedMemorySize = 4096
        let sharedMagic = UInt32(0x50564144)

        let fd = open(sharedMemoryPath, O_RDONLY)
        guard fd >= 0 else {
            return nil
        }

        let mapping = mmap(nil, sharedMemorySize, PROT_READ, MAP_SHARED, fd, 0)
        close(fd)
        guard mapping != MAP_FAILED, let mapping else {
            return nil
        }
        defer {
            munmap(mapping, sharedMemorySize)
        }

        let bytes = mapping.assumingMemoryBound(to: UInt8.self)
        let magic = loadSharedValue(UInt32.self, from: bytes, offset: 0)
        guard magic == sharedMagic else {
            return nil
        }

        return VirtualCableDriverDiagnostics(
            version: loadSharedValue(UInt32.self, from: bytes, offset: 4),
            capturedFrames: loadSharedValue(UInt64.self, from: bytes, offset: 16),
            ioCycles: loadSharedValue(UInt64.self, from: bytes, offset: 8),
            peak: loadSharedValue(Float32.self, from: bytes, offset: 24),
            rms: loadSharedValue(Float32.self, from: bytes, offset: 28),
            startCount: loadSharedValue(UInt64.self, from: bytes, offset: 32),
            stopCount: loadSharedValue(UInt64.self, from: bytes, offset: 40),
            willMixOutputCount: loadSharedValue(UInt64.self, from: bytes, offset: 48),
            willWriteMixCount: loadSharedValue(UInt64.self, from: bytes, offset: 56),
            doMixOutputCount: loadSharedValue(UInt64.self, from: bytes, offset: 64),
            doWriteMixCount: loadSharedValue(UInt64.self, from: bytes, offset: 72),
            lastOperation: loadSharedValue(UInt32.self, from: bytes, offset: 80),
            willThreadCount: loadSharedValue(UInt64.self, from: bytes, offset: 88),
            willCycleCount: loadSharedValue(UInt64.self, from: bytes, offset: 96),
            beginThreadCount: loadSharedValue(UInt64.self, from: bytes, offset: 104),
            beginCycleCount: loadSharedValue(UInt64.self, from: bytes, offset: 112),
            beginWriteMixCount: loadSharedValue(UInt64.self, from: bytes, offset: 120),
            endThreadCount: loadSharedValue(UInt64.self, from: bytes, offset: 128),
            endCycleCount: loadSharedValue(UInt64.self, from: bytes, offset: 136),
            endWriteMixCount: loadSharedValue(UInt64.self, from: bytes, offset: 144),
            lastBeginOperation: loadSharedValue(UInt32.self, from: bytes, offset: 152),
            lastEndOperation: loadSharedValue(UInt32.self, from: bytes, offset: 156),
            readStatus: .ok
        )
    }

    func loadSharedValue<T>(_ type: T.Type, from bytes: UnsafePointer<UInt8>, offset: Int) -> T {
        bytes.advanced(by: offset).withMemoryRebound(to: type, capacity: 1) { pointer in
            pointer.pointee
        }
    }

    func allDeviceIDs() -> [AudioObjectID] {
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
        var deviceIDs = Array(repeating: AudioObjectID(), count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs) == noErr else {
            return []
        }

        return deviceIDs
    }

    func defaultDevice(direction: AudioDeviceDirection) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: direction.defaultDeviceSelector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            return nil
        }
        return deviceID
    }

    func hasStreams(deviceID: AudioObjectID, direction: AudioDeviceDirection) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: direction.scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr else {
            return false
        }
        return dataSize >= MemoryLayout<AudioStreamID>.size
    }

    func makeDevice(deviceID: AudioObjectID, direction: AudioDeviceDirection, isDefault: Bool) -> AudioDevice {
        let name = stringProperty(deviceID: deviceID, selector: kAudioObjectPropertyName) ?? "Audio Device \(deviceID)"
        let uid = stringProperty(deviceID: deviceID, selector: kAudioDevicePropertyDeviceUID) ?? "\(deviceID)"
        let manufacturer = stringProperty(deviceID: deviceID, selector: kAudioObjectPropertyManufacturer) ?? "Core Audio"
        let volume = readVolume(deviceID: deviceID, direction: direction)
        let supportsVolume = supportsVolume(deviceID: deviceID, direction: direction)
        let supportsMute = supportsMute(deviceID: deviceID, direction: direction)
        let channelElements = channelElements(deviceID: deviceID, direction: direction)
        let channels = channelElements.enumerated().map { offset, element in
            AudioChannel(
                id: "\(direction.idPrefix)-\(deviceID)-channel-\(element)",
                name: channelName(offset: offset, total: channelElements.count),
                volume: readChannelVolume(deviceID: deviceID, direction: direction, channel: element) ?? volume
            )
        }

        return AudioDevice(
            id: "\(direction.idPrefix)-\(uid)",
            coreAudioObjectID: deviceID,
            name: name,
            description: "\(manufacturer) \(direction == .output ? "Output" : "Input")",
            iconName: direction.fallbackIconName,
            isDefault: isDefault,
            volume: volume,
            isMuted: readMuted(deviceID: deviceID, direction: direction),
            supportsVolume: supportsVolume,
            supportsMute: supportsMute,
            isLocked: true,
            selectedPort: "Default",
            availablePorts: ["Default"],
            channels: channels.isEmpty ? [
                AudioChannel(
                    id: "\(direction.idPrefix)-\(deviceID)-master",
                    name: "Master",
                    volume: volume
                )
            ] : channels
        )
    }

    func stringProperty(deviceID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
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

    func readVolume(deviceID: AudioObjectID, direction: AudioDeviceDirection) -> Double {
        if let masterVolume = readFloat32(
            deviceID: deviceID,
            selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            scope: direction.scope,
            element: kAudioObjectPropertyElementMain
        ) {
            return Double(masterVolume)
        }

        let channelVolumes = channelElements(deviceID: deviceID, direction: direction).compactMap {
            readChannelVolume(deviceID: deviceID, direction: direction, channel: $0)
        }
        guard !channelVolumes.isEmpty else {
            return 0
        }

        return channelVolumes.reduce(0, +) / Double(channelVolumes.count)
    }

    func supportsVolume(deviceID: AudioObjectID, direction: AudioDeviceDirection) -> Bool {
        isSettable(
            selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            scope: direction.scope,
            element: kAudioObjectPropertyElementMain,
            objectID: deviceID
        ) || channelElements(deviceID: deviceID, direction: direction).contains { channel in
            isSettable(
                selector: kAudioDevicePropertyVolumeScalar,
                scope: direction.scope,
                element: channel,
                objectID: deviceID
            )
        }
    }

    func readChannelVolume(deviceID: AudioObjectID, direction: AudioDeviceDirection, channel: AudioObjectPropertyElement) -> Double? {
        guard let value = readFloat32(
            deviceID: deviceID,
            selector: kAudioDevicePropertyVolumeScalar,
            scope: direction.scope,
            element: channel
        ) else {
            return nil
        }
        return Double(value)
    }

    func readMuted(deviceID: AudioObjectID, direction: AudioDeviceDirection) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: direction.scope,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(deviceID, &address) else {
            return false
        }

        var muteValue: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &muteValue)
        guard status == noErr else {
            return false
        }
        return muteValue != 0
    }

    func supportsMute(deviceID: AudioObjectID, direction: AudioDeviceDirection) -> Bool {
        isSettable(
            selector: kAudioDevicePropertyMute,
            scope: direction.scope,
            element: kAudioObjectPropertyElementMain,
            objectID: deviceID
        )
    }

    func readFloat32Unchecked(
        deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> (value: Float32, status: OSStatus) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )

        var value = Float32(0)
        var dataSize = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value)
        return (value, status)
    }

    func readUInt32Unchecked(
        deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> (value: UInt32, status: OSStatus) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )

        var value = UInt32(0)
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value)
        return (value, status)
    }

    func readUInt64Unchecked(
        deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> (value: UInt64, status: OSStatus) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )

        var value = UInt64(0)
        var dataSize = UInt32(MemoryLayout<UInt64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value)
        return (value, status)
    }

    func readFloat32(
        deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Float32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )

        guard AudioObjectHasProperty(deviceID, &address) else {
            return nil
        }

        var value = Float32(0)
        var dataSize = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value)
        guard status == noErr else {
            return nil
        }

        return value
    }

    func readUInt32(
        deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )

        guard AudioObjectHasProperty(deviceID, &address) else {
            return nil
        }

        var value = UInt32(0)
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value)
        guard status == noErr else {
            return nil
        }

        return value
    }

    func readUInt64(
        deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> UInt64? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )

        guard AudioObjectHasProperty(deviceID, &address) else {
            return nil
        }

        var value = UInt64(0)
        var dataSize = UInt32(MemoryLayout<UInt64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value)
        guard status == noErr else {
            return nil
        }

        return value
    }

    func channelElements(deviceID: AudioObjectID, direction: AudioDeviceDirection) -> [AudioObjectPropertyElement] {
        let channelCount = streamChannelCount(deviceID: deviceID, direction: direction)
        guard channelCount > 0 else {
            return []
        }
        return (1...channelCount).map { AudioObjectPropertyElement($0) }
    }

    func streamChannelCount(deviceID: AudioObjectID, direction: AudioDeviceDirection) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: direction.scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return 0
        }

        let bufferList = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferList.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferList) == noErr else {
            return 0
        }

        let audioBufferList = bufferList.bindMemory(to: AudioBufferList.self, capacity: 1)
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    func channelName(offset: Int, total: Int) -> String {
        if total == 1 {
            return "Mono"
        }

        switch offset {
        case 0: return "Front Left"
        case 1: return "Front Right"
        default: return "Channel \(offset + 1)"
        }
    }

    func settableSet(
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement,
        objectID: AudioObjectID,
        dataSize: UInt32,
        data: UnsafeRawPointer
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )

        var isSettable = DarwinBoolean(false)
        guard AudioObjectHasProperty(objectID, &address),
              AudioObjectIsPropertySettable(objectID, &address, &isSettable) == noErr,
              isSettable.boolValue else {
            return false
        }

        return AudioObjectSetPropertyData(objectID, &address, 0, nil, dataSize, data) == noErr
    }

    func isSettable(
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement,
        objectID: AudioObjectID
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )

        var isSettable = DarwinBoolean(false)
        return AudioObjectHasProperty(objectID, &address)
            && AudioObjectIsPropertySettable(objectID, &address, &isSettable) == noErr
            && isSettable.boolValue
    }
}
