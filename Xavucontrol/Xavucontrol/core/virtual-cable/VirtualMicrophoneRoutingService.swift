import AudioToolbox
import AVFoundation
import CoreAudio
import Darwin
import Foundation

struct VirtualMicrophoneRouteError: Error, LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

actor VirtualMicrophoneRoutingService {
    static let shared = VirtualMicrophoneRoutingService()

    private var session: VirtualMicrophoneMixerSession?
    private var activeSignature = ""

    func route(from sourceDevice: AudioDevice) async throws -> String {
        try await route(inputDevices: [sourceDevice], playbackStreams: [])
    }

    func route(inputDevices: [AudioDevice], playbackStreams: [AppAudioStream]) async throws -> String {
        let inputDevices = inputDevices.filter { $0.coreAudioObjectID != nil }
        guard !inputDevices.isEmpty || !playbackStreams.isEmpty else {
            throw VirtualMicrophoneRouteError(message: "Virtual mic has no enabled audio sources")
        }

        if !inputDevices.isEmpty {
            try await ensureMicrophoneAccess()
        }

        let signature = Self.signature(inputDevices: inputDevices, playbackStreams: playbackStreams)
        if activeSignature == signature, session?.isRunning == true {
            return Self.summary(inputDevices: inputDevices, playbackStreams: playbackStreams)
        }

        session?.stop()
        let nextSession = VirtualMicrophoneMixerSession(
            inputDevices: inputDevices,
            playbackStreams: playbackStreams
        )
        try nextSession.start()
        session = nextSession
        activeSignature = signature
        return Self.summary(inputDevices: inputDevices, playbackStreams: playbackStreams)
    }

    func stop() {
        session?.stop()
        session = nil
        activeSignature = ""
    }

    func microphoneAccessStatusText() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return "Microphone access granted"
        case .notDetermined:
            return "Microphone access not requested yet"
        case .denied:
            return "Microphone access denied"
        case .restricted:
            return "Microphone access restricted"
        @unknown default:
            return "Microphone access status is unknown"
        }
    }

    func requestMicrophoneAccess() async -> String {
        do {
            try await ensureMicrophoneAccess()
            return microphoneAccessStatusText()
        } catch {
            return error.localizedDescription
        }
    }

    private static func signature(inputDevices: [AudioDevice], playbackStreams: [AppAudioStream]) -> String {
        let inputPart = inputDevices.map(\.id).sorted().joined(separator: "|")
        let playbackPart = playbackStreams.map(\.preferenceKey).sorted().joined(separator: "|")
        return "inputs:\(inputPart);playback:\(playbackPart)"
    }

    private static func summary(inputDevices: [AudioDevice], playbackStreams: [AppAudioStream]) -> String {
        let sourceNames = (inputDevices.map(\.name) + playbackStreams.map { "\($0.appName) playback" })
            .sorted()
            .joined(separator: ", ")
        return "Virtual microphone mixer active: \(sourceNames) -> Xavucontrol Virtual Mic"
    }

    private func ensureMicrophoneAccess() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let isGranted = await AVCaptureDevice.requestAccess(for: .audio)
            if isGranted {
                return
            }
            throw VirtualMicrophoneRouteError(message: "Microphone access was denied")
        case .denied, .restricted:
            throw VirtualMicrophoneRouteError(message: "Microphone access is disabled in macOS Privacy settings")
        @unknown default:
            throw VirtualMicrophoneRouteError(message: "Microphone access status is unknown")
        }
    }
}

private nonisolated final class VirtualMicrophoneMixerSession {
    private let sharedPath = "/tmp/xavucontrol_virtual_cable_diag_v1"
    private let sharedMagic = UInt32(0x50564144)
    private let sharedVersion = UInt32(6)
    private let sharedAudioCapacityBytes = 2 * 1024 * 1024
    private let sharedMicrophoneDataOffset = 4096 + 2 * 1024 * 1024
    private let sharedMappingSize = 4096 + 2 * 1024 * 1024 * 2

    private let microphoneCapacityOffset = 200
    private let microphoneBytesPerFrameOffset = 204
    private let microphoneSampleRateOffset = 208
    private let microphoneWriteBytePositionOffset = 216
    private let microphoneReadBytePositionOffset = 224
    private let microphoneFramesWrittenOffset = 232

    private let inputDevices: [AudioDevice]
    private let playbackStreams: [AppAudioStream]
    private var inputSources: [VirtualMicrophoneInputSource] = []
    private var playbackSources: [VirtualMicrophonePlaybackSource] = []
    private var sharedPointer: UnsafeMutableRawPointer?
    private var sharedFD: Int32 = -1
    private var mixerTimer: DispatchSourceTimer?
    private var diagnosticsTimer: DispatchSourceTimer?
    private var mixedBytes: UInt64 = 0
    private var droppedBytes: UInt64 = 0
    private var lastMixTimestampNanoseconds: UInt64 = 0
    private var fractionalMixFrames = 0.0

    private(set) var isRunning = false

    init(inputDevices: [AudioDevice], playbackStreams: [AppAudioStream]) {
        self.inputDevices = inputDevices
        self.playbackStreams = playbackStreams
    }

    deinit {
        stop()
    }

    func start() throws {
        guard !isRunning else {
            return
        }

        try openSharedAudio()
        inputSources = try inputDevices.map { device in
            guard let objectID = device.coreAudioObjectID else {
                throw VirtualMicrophoneRouteError(message: "Source input device has no Core Audio object ID")
            }
            return VirtualMicrophoneInputSource(
                sourceDeviceObjectID: objectID,
                sourceDeviceName: device.name
            )
        }
        playbackSources = try playbackStreams.map { stream in
            try VirtualMicrophonePlaybackSource(stream: stream)
        }

        for source in inputSources {
            try source.start()
        }
        for source in playbackSources {
            try source.start()
        }

        startMixerTimer()
        startDiagnosticsTimer()
        isRunning = true
    }

    func stop() {
        mixerTimer?.cancel()
        mixerTimer = nil
        diagnosticsTimer?.cancel()
        diagnosticsTimer = nil

        inputSources.forEach { $0.stop() }
        playbackSources.forEach { $0.stop() }
        inputSources.removeAll()
        playbackSources.removeAll()

        if let sharedPointer {
            munmap(sharedPointer, sharedMappingSize)
            self.sharedPointer = nil
        }
        if sharedFD >= 0 {
            close(sharedFD)
            sharedFD = -1
        }

        isRunning = false
    }

    private func openSharedAudio() throws {
        sharedFD = open(sharedPath, O_CREAT | O_RDWR, 0o666)
        guard sharedFD >= 0 else {
            throw VirtualMicrophoneRouteError(message: "Virtual microphone shared audio buffer is not available: \(Self.describeErrno())")
        }

        guard ftruncate(sharedFD, off_t(sharedMappingSize)) == 0 else {
            let error = Self.describeErrno()
            close(sharedFD)
            sharedFD = -1
            throw VirtualMicrophoneRouteError(message: "Unable to size virtual microphone shared audio buffer: \(error)")
        }

        let mapping = mmap(nil, sharedMappingSize, PROT_READ | PROT_WRITE, MAP_SHARED, sharedFD, 0)
        guard mapping != MAP_FAILED else {
            let error = Self.describeErrno()
            close(sharedFD)
            sharedFD = -1
            throw VirtualMicrophoneRouteError(message: "Unable to map virtual microphone shared audio buffer: \(error)")
        }

        sharedPointer = mapping
        initializeSharedHeaderIfNeeded()

        let version = readUInt32(offset: 4)
        guard version >= sharedVersion else {
            throw VirtualMicrophoneRouteError(message: "Installed virtual cable driver is v\(version); install latest bundled driver v6")
        }

        writeUInt32(UInt32(sharedAudioCapacityBytes), offset: microphoneCapacityOffset)
        writeUInt32(8, offset: microphoneBytesPerFrameOffset)
        writeFloat64(48_000, offset: microphoneSampleRateOffset)
        resetMicrophoneRing()
    }

    private func initializeSharedHeaderIfNeeded() {
        let currentMagic = readUInt32(offset: 0)
        let currentVersion = readUInt32(offset: 4)
        if currentMagic != sharedMagic || currentVersion < sharedVersion {
            writeUInt32(sharedMagic, offset: 0)
            writeUInt32(sharedVersion, offset: 4)
            writeUInt64(0, offset: 16)
            writeFloat32(0, offset: 24)
            writeFloat32(0, offset: 28)
            writeUInt32(UInt32(sharedAudioCapacityBytes), offset: 160)
            writeUInt32(8, offset: 164)
            writeFloat64(48_000, offset: 168)
            writeUInt64(0, offset: 176)
            writeUInt64(0, offset: 184)
        }

        writeUInt32(UInt32(sharedAudioCapacityBytes), offset: microphoneCapacityOffset)
        writeUInt32(8, offset: microphoneBytesPerFrameOffset)
        writeFloat64(48_000, offset: microphoneSampleRateOffset)
    }

    private func resetMicrophoneRing() {
        writeUInt64(0, offset: microphoneWriteBytePositionOffset)
        writeUInt64(0, offset: microphoneReadBytePositionOffset)
        writeUInt64(0, offset: microphoneFramesWrittenOffset)
        guard let sharedPointer else { return }
        memset(sharedPointer.advanced(by: sharedMicrophoneDataOffset), 0, sharedAudioCapacityBytes)
    }

    private func startMixerTimer() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        lastMixTimestampNanoseconds = DispatchTime.now().uptimeNanoseconds
        fractionalMixFrames = 0
        timer.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            self?.mixNextBlock()
        }
        mixerTimer = timer
        timer.resume()
    }

    private func mixNextBlock() {
        let frameCount = nextMixFrameCount()
        guard frameCount > 0 else {
            return
        }

        let sampleCount = frameCount * 2
        let sources: [VirtualMicrophoneBufferedSource] = inputSources + playbackSources
        guard !sources.isEmpty else {
            return
        }

        var mixed = Array(repeating: Float32.zero, count: sampleCount)
        var scratch = Array(repeating: Float32.zero, count: sampleCount)
        var activeSourceCount = 0

        for source in sources {
            scratch.withUnsafeMutableBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                source.readSamples(into: baseAddress, count: sampleCount)
            }
            let hasSignal = scratch.contains { $0 != 0 }
            if hasSignal {
                activeSourceCount += 1
            }
            for index in 0..<sampleCount {
                mixed[index] += scratch[index]
            }
        }

        if activeSourceCount > 1 {
            let makeupGain = Float32(1.0 / sqrt(Double(activeSourceCount)))
            for index in 0..<sampleCount {
                mixed[index] *= makeupGain
            }
        }

        for index in 0..<sampleCount {
            mixed[index] = min(1, max(-1, mixed[index]))
        }

        mixed.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }
            writeMicrophoneAudio(baseAddress.assumingMemoryBound(to: UInt8.self), byteCount: rawBuffer.count)
        }
    }

    private func nextMixFrameCount() -> Int {
        let now = DispatchTime.now().uptimeNanoseconds
        if lastMixTimestampNanoseconds == 0 {
            lastMixTimestampNanoseconds = now
            return 0
        }

        let elapsedNanoseconds = now &- lastMixTimestampNanoseconds
        lastMixTimestampNanoseconds = now

        let exactFrames = (Double(elapsedNanoseconds) / 1_000_000_000.0 * 48_000.0) + fractionalMixFrames
        var frameCount = Int(exactFrames.rounded(.down))
        fractionalMixFrames = exactFrames - Double(frameCount)

        if frameCount > 2048 {
            frameCount = 2048
            fractionalMixFrames = 0
        }
        return frameCount
    }

    private func writeMicrophoneAudio(_ source: UnsafePointer<UInt8>, byteCount: Int) {
        guard let sharedPointer, byteCount > 0 else {
            return
        }

        var source = source
        var byteCount = byteCount
        if byteCount > sharedAudioCapacityBytes {
            let bytesToSkip = byteCount - sharedAudioCapacityBytes
            source = source.advanced(by: bytesToSkip)
            byteCount = sharedAudioCapacityBytes
            droppedBytes = droppedBytes &+ UInt64(bytesToSkip)
        }

        let capacity = UInt64(sharedAudioCapacityBytes)
        let readPosition = readUInt64(offset: microphoneReadBytePositionOffset)
        var writePosition = readUInt64(offset: microphoneWriteBytePositionOffset)
        let availableAfterWrite = (writePosition &- readPosition) &+ UInt64(byteCount)
        if availableAfterWrite > capacity {
            let bytesToDrop = availableAfterWrite - capacity
            writePosition = writePosition &+ bytesToDrop
            droppedBytes = droppedBytes &+ bytesToDrop
        }

        let audioBase = sharedPointer.advanced(by: sharedMicrophoneDataOffset).assumingMemoryBound(to: UInt8.self)
        let writeOffset = Int(writePosition % capacity)
        let firstChunk = min(byteCount, sharedAudioCapacityBytes - writeOffset)
        memcpy(audioBase.advanced(by: writeOffset), source, firstChunk)
        if firstChunk < byteCount {
            memcpy(audioBase, source.advanced(by: firstChunk), byteCount - firstChunk)
        }

        let nextWritePosition = writePosition &+ UInt64(byteCount)
        writeUInt64(nextWritePosition, offset: microphoneWriteBytePositionOffset)
        let framesWritten = readUInt64(offset: microphoneFramesWrittenOffset) &+ UInt64(byteCount / 8)
        writeUInt64(framesWritten, offset: microphoneFramesWrittenOffset)
        mixedBytes = mixedBytes &+ UInt64(byteCount)
    }

    private func startDiagnosticsTimer() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 2, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            NSLog(
                "Xavucontrol virtual microphone mixer inputs=%d playback=%d mixed=%llu dropped=%llu write=%llu read=%llu sources=%@",
                self.inputSources.count,
                self.playbackSources.count,
                self.mixedBytes,
                self.droppedBytes,
                self.readUInt64(offset: self.microphoneWriteBytePositionOffset),
                self.readUInt64(offset: self.microphoneReadBytePositionOffset),
                (self.inputSources.map(\.sourceName) + self.playbackSources.map(\.sourceName)).joined(separator: ", ")
            )
        }
        diagnosticsTimer = timer
        timer.resume()
    }

    private func readUInt32(offset: Int) -> UInt32 {
        guard let sharedPointer else { return 0 }
        return sharedPointer.advanced(by: offset).assumingMemoryBound(to: UInt32.self).pointee
    }

    private func writeUInt32(_ value: UInt32, offset: Int) {
        sharedPointer?.advanced(by: offset).assumingMemoryBound(to: UInt32.self).pointee = value
    }

    private func readUInt64(offset: Int) -> UInt64 {
        guard let sharedPointer else { return 0 }
        return sharedPointer.advanced(by: offset).assumingMemoryBound(to: UInt64.self).pointee
    }

    private func writeUInt64(_ value: UInt64, offset: Int) {
        sharedPointer?.advanced(by: offset).assumingMemoryBound(to: UInt64.self).pointee = value
    }

    private func writeFloat64(_ value: Float64, offset: Int) {
        sharedPointer?.advanced(by: offset).assumingMemoryBound(to: Float64.self).pointee = value
    }

    private func writeFloat32(_ value: Float32, offset: Int) {
        sharedPointer?.advanced(by: offset).assumingMemoryBound(to: Float32.self).pointee = value
    }

    private static func describeErrno() -> String {
        String(cString: strerror(errno))
    }
}

private nonisolated protocol VirtualMicrophoneBufferedSource: AnyObject {
    var sourceName: String { get }
    func start() throws
    func stop()
    func readSamples(into destination: UnsafeMutablePointer<Float32>, count: Int)
}

private nonisolated final class VirtualMicrophoneInputSource: VirtualMicrophoneBufferedSource {
    let sourceName: String

    private let sourceDeviceObjectID: AudioObjectID
    private let ringBuffer = FloatRingBuffer(capacity: 48_000 * 2)
    private var queue: AudioQueueRef?
    private var queueBuffers: [AudioQueueBufferRef] = []

    init(sourceDeviceObjectID: AudioObjectID, sourceDeviceName: String) {
        self.sourceDeviceObjectID = sourceDeviceObjectID
        self.sourceName = sourceDeviceName
    }

    deinit {
        stop()
    }

    func start() throws {
        var inputQueue: AudioQueueRef?
        var format = Self.microphoneFormat(sampleRate: 48_000)
        let context = Unmanaged.passUnretained(self).toOpaque()

        try check(AudioQueueNewInput(&format, virtualMicrophoneInputProc, context, nil, nil, 0, &inputQueue), "Create virtual microphone input queue")
        guard let inputQueue else {
            throw VirtualMicrophoneRouteError(message: "AudioQueue input could not be created")
        }

        let sourceUID = try readDeviceUID(deviceID: sourceDeviceObjectID)
        var uid = sourceUID as CFString
        try check(withUnsafePointer(to: &uid) { pointer in
            AudioQueueSetProperty(
                inputQueue,
                kAudioQueueProperty_CurrentDevice,
                pointer,
                UInt32(MemoryLayout<CFString>.size)
            )
        }, "Set virtual microphone source device")

        let bufferByteSize = UInt32(Int(format.mBytesPerFrame) * 1024)
        for _ in 0..<4 {
            var buffer: AudioQueueBufferRef?
            try check(AudioQueueAllocateBuffer(inputQueue, bufferByteSize, &buffer), "Allocate virtual microphone input buffer")
            guard let buffer else { continue }
            queueBuffers.append(buffer)
            try check(AudioQueueEnqueueBuffer(inputQueue, buffer, 0, nil), "Prime virtual microphone input buffer")
        }

        queue = inputQueue
        try check(AudioQueueStart(inputQueue, nil), "Start virtual microphone input queue")
    }

    func stop() {
        if let queue {
            AudioQueueStop(queue, true)
            AudioQueueDispose(queue, true)
            self.queue = nil
        }
        queueBuffers.removeAll()
    }

    func readSamples(into destination: UnsafeMutablePointer<Float32>, count: Int) {
        ringBuffer.read(into: destination, count: count)
    }

    fileprivate func handleInputBuffer(queue: AudioQueueRef, buffer: AudioQueueBufferRef) {
        let byteCount = Int(buffer.pointee.mAudioDataByteSize)
        if byteCount > 0 {
            let sampleCount = byteCount / MemoryLayout<Float32>.size
            ringBuffer.write(samples: buffer.pointee.mAudioData.assumingMemoryBound(to: Float32.self), count: sampleCount)
        }
        AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    }

    private static func microphoneFormat(sampleRate: Float64) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
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
        }, "Read virtual microphone source device UID")
        return value as String
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw VirtualMicrophoneRouteError(message: "\(operation) failed: \(status)")
        }
    }
}

private nonisolated final class VirtualMicrophonePlaybackSource: VirtualMicrophoneBufferedSource {
    let sourceName: String

    private let stream: AppAudioStream
    private let processObjectIDs: [AudioObjectID]
    private let sourceDeviceUID: String
    private let ringBuffer = FloatRingBuffer(capacity: 48_000 * 2)
    private var tapFormat = AudioStreamBasicDescription()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var didStart = false

    init(stream: AppAudioStream) throws {
        guard let processObjectID = ProcessTapRoutingService.processObjectID(from: stream.id) else {
            throw VirtualMicrophoneRouteError(message: "Unable to read Core Audio process object ID from \(stream.appName)")
        }
        self.stream = stream
        self.processObjectIDs = ProcessTapRoutingService.relatedOutputProcessObjectIDs(for: processObjectID)
        let virtualSourceDeviceUID = ProcessTapRoutingService.sourceDeviceUID(
            processObjectID: processObjectID,
            assignedDeviceID: stream.assignedDeviceID
        )
        let hardwareSourceDeviceUID = ProcessTapRoutingService.diagnosticHardwareSourceDeviceUID(
            processObjectID: processObjectID,
            assignedDeviceID: stream.assignedDeviceID
        )
        if let assignedDeviceID = stream.assignedDeviceID,
           !assignedDeviceID.localizedCaseInsensitiveContains("xavucontrol.virtualcable") {
            self.sourceDeviceUID = hardwareSourceDeviceUID
        } else {
            self.sourceDeviceUID = virtualSourceDeviceUID
        }
        self.sourceName = stream.appName
    }

    deinit {
        stop()
    }

    func start() throws {
        guard !didStart else {
            return
        }
        guard #available(macOS 14.2, *) else {
            throw VirtualMicrophoneRouteError(message: "Process taps require macOS 14.2 or newer")
        }

        let tapDescription = CATapDescription(
            processes: processObjectIDs,
            deviceUID: sourceDeviceUID,
            stream: 0
        )
        tapDescription.name = "Xavucontrol mic tap - \(stream.appName)"
        tapDescription.isPrivate = true
        tapDescription.isExclusive = false
        tapDescription.muteBehavior = CATapMuteBehavior.unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(tapDescription, &newTapID), "Create virtual microphone process tap")
        tapID = newTapID

        let tapUID = try readTapUID(tapID: tapID)
        aggregateDeviceID = try createAggregateDevice(tapUID: tapUID)
        tapFormat = try readTapFormat(tapID: tapID)

        var createdIOProcID: AudioDeviceIOProcID?
        let context = Unmanaged.passUnretained(self).toOpaque()
        try check(AudioDeviceCreateIOProcID(aggregateDeviceID, virtualMicrophonePlaybackInputProc, context, &createdIOProcID), "Create virtual microphone tap IOProc")
        guard let createdIOProcID else {
            throw VirtualMicrophoneRouteError(message: "Core Audio did not return a virtual microphone tap IOProc ID")
        }

        ioProcID = createdIOProcID
        try check(AudioDeviceStart(aggregateDeviceID, createdIOProcID), "Start virtual microphone tap IOProc")
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

    func readSamples(into destination: UnsafeMutablePointer<Float32>, count: Int) {
        ringBuffer.read(into: destination, count: count)
    }

    fileprivate func handleTapInput(_ inputData: UnsafePointer<AudioBufferList>?) {
        guard let inputData else {
            return
        }

        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        if shouldTreatInputAsPlanarFloat(buffers: buffers) {
            writePlanarFloatInput(buffers: buffers)
        } else if let buffer = buffers.first,
                  let data = buffer.mData,
                  buffer.mDataByteSize > 0 {
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size
            ringBuffer.write(samples: data.assumingMemoryBound(to: Float32.self), count: count)
        }
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
        for frame in 0..<frameCount {
            interleaved[frame * 2] = left[frame]
            interleaved[frame * 2 + 1] = right[frame]
        }
        interleaved.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            ringBuffer.write(samples: baseAddress, count: interleaved.count)
        }
    }

    private func shouldTreatInputAsPlanarFloat(buffers: UnsafeMutableAudioBufferListPointer) -> Bool {
        guard buffers.count >= 2 else {
            return false
        }

        let isFloat = (tapFormat.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        return isFloat && isNonInterleaved
    }

    private func createAggregateDevice(tapUID: String) throws -> AudioObjectID {
        let aggregateUID = "org.moroz.xavucontrol.virtual-mic.tap.\(stream.id).\(UUID().uuidString)"
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Xavucontrol Mic Tap - \(stream.appName)",
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
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID), "Create virtual microphone tap aggregate device")
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
        }, "Read virtual microphone tap UID")
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
        try check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &dataSize, &format), "Read virtual microphone tap format")
        return format
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw VirtualMicrophoneRouteError(message: "\(operation) failed: \(status)")
        }
    }
}

private nonisolated final class FloatRingBuffer {
    private let lock = NSLock()
    private var storage: [Float32]
    private var readIndex = 0
    private var writeIndex = 0
    private var available = 0

    init(capacity: Int) {
        storage = Array(repeating: 0, count: max(capacity, 1))
    }

    func write(samples: UnsafePointer<Float32>, count: Int) {
        guard count > 0 else {
            return
        }

        lock.lock()
        defer { lock.unlock() }

        for offset in 0..<count {
            storage[writeIndex] = samples[offset]
            writeIndex = (writeIndex + 1) % storage.count

            if available == storage.count {
                readIndex = (readIndex + 1) % storage.count
            } else {
                available += 1
            }
        }
    }

    func read(into destination: UnsafeMutablePointer<Float32>, count: Int) {
        guard count > 0 else {
            return
        }

        lock.lock()
        defer { lock.unlock() }

        let samplesToRead = min(count, available)
        for offset in 0..<samplesToRead {
            destination[offset] = storage[readIndex]
            readIndex = (readIndex + 1) % storage.count
        }
        if samplesToRead < count {
            for offset in samplesToRead..<count {
                destination[offset] = 0
            }
        }
        available -= samplesToRead
    }
}

nonisolated private let virtualMicrophoneInputProc: AudioQueueInputCallback = { clientData, queue, buffer, _, _, _ in
    guard let clientData else {
        return
    }

    let source = Unmanaged<VirtualMicrophoneInputSource>.fromOpaque(clientData).takeUnretainedValue()
    source.handleInputBuffer(queue: queue, buffer: buffer)
}

nonisolated private let virtualMicrophonePlaybackInputProc: AudioDeviceIOProc = { _, _, inputData, _, _, _, clientData in
    guard let clientData else {
        return noErr
    }

    let source = Unmanaged<VirtualMicrophonePlaybackSource>.fromOpaque(clientData).takeUnretainedValue()
    source.handleTapInput(inputData)
    return noErr
}
