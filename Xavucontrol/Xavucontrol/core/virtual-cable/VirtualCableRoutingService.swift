import AudioToolbox
import CoreAudio
import Darwin
import Foundation

struct VirtualCableRouteError: Error, LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

actor VirtualCableRoutingService {
    static let shared = VirtualCableRoutingService()

    private var sessions: [String: VirtualCableRouteSession] = [:]

    func route(stream: AppAudioStream, to targetDevice: AudioDevice) async throws -> String {
        guard stream.direction == .playback else {
            throw VirtualCableRouteError(message: "Virtual cable routing is available for playback streams only")
        }

        guard let targetDeviceObjectID = targetDevice.coreAudioObjectID else {
            throw VirtualCableRouteError(message: "Target device has no Core Audio object ID")
        }

        sessions.values.forEach { $0.stop() }
        sessions.removeAll()

        let session = VirtualCableRouteSession(
            streamID: stream.id,
            appName: stream.appName,
            targetDeviceObjectID: targetDeviceObjectID,
            targetDeviceName: targetDevice.name
        )
        try session.start()
        sessions[stream.id] = session

        return "Virtual cable mixed route active: \(stream.appName) -> \(targetDevice.name). Only one mixed route can be active until per-app capture is implemented."
    }

    func stop(streamID: String) {
        sessions[streamID]?.stop()
        sessions[streamID] = nil
    }

    func stopAll() {
        sessions.values.forEach { $0.stop() }
        sessions.removeAll()
    }
}

private nonisolated final class VirtualCableRouteSession {
    private let streamID: String
    private let appName: String
    private let targetDeviceObjectID: AudioObjectID
    private let targetDeviceName: String
    private let ringBuffer = VirtualCableByteRingBuffer(capacity: 48_000 * 8 * 4)

    private let sharedPath = "/tmp/xavucontrol_virtual_cable_diag_v1"
    private let sharedMagic = UInt32(0x50564144)
    private let sharedAudioDataOffset = 4096
    private let sharedAudioCapacityBytes = 2 * 1024 * 1024
    private let sharedMappingSize = 4096 + 2 * 1024 * 1024

    private var sharedPointer: UnsafeMutableRawPointer?
    private var sharedFD: Int32 = -1
    private var readBytePosition: UInt64 = 0
    private var outputFormat = VirtualCableRouteSession.outputFormat(sampleRate: 48_000)

    private var queue: AudioQueueRef?
    private var queueBuffers: [AudioQueueBufferRef] = []
    private var pumpTimer: DispatchSourceTimer?
    private var diagnosticsTimer: DispatchSourceTimer?
    private var requestedOutputDeviceUID = ""
    private var actualOutputDeviceUID = ""
    private var capturedBytes: UInt64 = 0
    private var playedBytes: UInt64 = 0
    private var underflowCount: UInt64 = 0
    private var skippedBytes: UInt64 = 0
    private var didStart = false

    init(
        streamID: String,
        appName: String,
        targetDeviceObjectID: AudioObjectID,
        targetDeviceName: String
    ) {
        self.streamID = streamID
        self.appName = appName
        self.targetDeviceObjectID = targetDeviceObjectID
        self.targetDeviceName = targetDeviceName
    }

    deinit {
        stop()
    }

    func start() throws {
        guard !didStart else {
            return
        }

        try openSharedAudio()
        outputFormat = VirtualCableRouteSession.outputFormat(sampleRate: readFloat64(offset: 168))
        try startOutputQueue(format: outputFormat)
        startPumpTimer()
        startDiagnosticsTimer()
        didStart = true
    }

    func stop() {
        pumpTimer?.cancel()
        pumpTimer = nil
        diagnosticsTimer?.cancel()
        diagnosticsTimer = nil

        if let queue {
            AudioQueueStop(queue, true)
            AudioQueueDispose(queue, true)
            self.queue = nil
        }
        queueBuffers.removeAll()

        if let sharedPointer {
            munmap(sharedPointer, sharedMappingSize)
            self.sharedPointer = nil
        }
        if sharedFD >= 0 {
            close(sharedFD)
            sharedFD = -1
        }

        didStart = false
    }

    private func openSharedAudio() throws {
        sharedFD = open(sharedPath, O_RDONLY)
        guard sharedFD >= 0 else {
            throw VirtualCableRouteError(message: "Virtual cable shared audio buffer is not available")
        }

        let mapping = mmap(nil, sharedMappingSize, PROT_READ, MAP_SHARED, sharedFD, 0)
        guard mapping != MAP_FAILED else {
            close(sharedFD)
            sharedFD = -1
            throw VirtualCableRouteError(message: "Unable to map virtual cable shared audio buffer")
        }

        sharedPointer = mapping
        guard readUInt32(offset: 0) == sharedMagic else {
            throw VirtualCableRouteError(message: "Virtual cable shared audio buffer has invalid magic")
        }

        let version = readUInt32(offset: 4)
        guard version >= 5 else {
            throw VirtualCableRouteError(message: "Installed virtual cable driver is v\(version); install latest bundled driver v5")
        }

        readBytePosition = readUInt64(offset: 176)
        NSLog(
            "Xavucontrol virtual cable shared audio open version=%u capacity=%u bytesPerFrame=%u sampleRate=%.1f write=%llu audioFrames=%llu driverFrames=%llu",
            version,
            readUInt32(offset: 160),
            readUInt32(offset: 164),
            readFloat64(offset: 168),
            readBytePosition,
            readUInt64(offset: 184),
            readUInt64(offset: 16)
        )
    }

    private func startOutputQueue(format: AudioStreamBasicDescription) throws {
        var outputQueue: AudioQueueRef?
        let context = Unmanaged.passUnretained(self).toOpaque()
        var mutableFormat = format

        try check(AudioQueueNewOutput(&mutableFormat, virtualCableOutputProc, context, nil, nil, 0, &outputQueue), "Create virtual cable output queue")
        guard let outputQueue else {
            throw VirtualCableRouteError(message: "AudioQueue output could not be created")
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
        }, "Set virtual cable output device")
        actualOutputDeviceUID = readAudioQueueCurrentDevice(outputQueue) ?? "unreadable"
        AudioQueueSetParameter(outputQueue, kAudioQueueParam_Volume, 1.0)

        let bufferByteSize = UInt32(Int(format.mBytesPerFrame) * 1024)
        for _ in 0..<4 {
            var buffer: AudioQueueBufferRef?
            try check(AudioQueueAllocateBuffer(outputQueue, bufferByteSize, &buffer), "Allocate virtual cable output buffer")
            guard let buffer else { continue }
            queueBuffers.append(buffer)
            fillOutputBuffer(buffer)
            try check(AudioQueueEnqueueBuffer(outputQueue, buffer, 0, nil), "Prime virtual cable output buffer")
        }

        queue = outputQueue
        try check(AudioQueueStart(outputQueue, nil), "Start virtual cable output queue")
    }

    private func startPumpTimer() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            self?.pumpSharedAudio()
        }
        pumpTimer = timer
        timer.resume()
    }

    private func pumpSharedAudio() {
        guard let sharedPointer else {
            return
        }

        let writePosition = readUInt64(offset: 176)
        if writePosition == readBytePosition {
            return
        }

        let capacity = UInt64(sharedAudioCapacityBytes)
        let available = writePosition &- readBytePosition
        if available > capacity {
            skippedBytes = skippedBytes &+ (available - capacity)
            readBytePosition = writePosition &- capacity
        }

        let bytesToRead = Int(min(writePosition &- readBytePosition, 64 * 1024))
        guard bytesToRead > 0 else {
            return
        }

        var bytes = Array(repeating: UInt8.zero, count: bytesToRead)
        let audioBase = sharedPointer.advanced(by: sharedAudioDataOffset).assumingMemoryBound(to: UInt8.self)
        let readOffset = Int(readBytePosition % capacity)
        let firstChunk = min(bytesToRead, sharedAudioCapacityBytes - readOffset)
        bytes.withUnsafeMutableBufferPointer { destination in
            guard let baseAddress = destination.baseAddress else {
                return
            }

            memcpy(baseAddress, audioBase.advanced(by: readOffset), firstChunk)
            if firstChunk < bytesToRead {
                memcpy(baseAddress.advanced(by: firstChunk), audioBase, bytesToRead - firstChunk)
            }
        }

        bytes.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else {
                return
            }

            ringBuffer.write(bytes: baseAddress, count: bytesToRead)
        }
        readBytePosition = readBytePosition &+ UInt64(bytesToRead)
        capturedBytes = capturedBytes &+ UInt64(bytesToRead)
    }

    private func fillOutputBuffer(_ buffer: AudioQueueBufferRef) {
        let capacity = Int(buffer.pointee.mAudioDataBytesCapacity)
        let written = ringBuffer.read(into: buffer.pointee.mAudioData.assumingMemoryBound(to: UInt8.self), count: capacity)
        playedBytes = playedBytes &+ UInt64(written)

        if written < capacity {
            underflowCount = underflowCount &+ 1
            memset(buffer.pointee.mAudioData.advanced(by: written), 0, capacity - written)
        }

        buffer.pointee.mAudioDataByteSize = UInt32(capacity)
    }

    fileprivate func handleOutputBuffer(queue: AudioQueueRef, buffer: AudioQueueBufferRef) {
        fillOutputBuffer(buffer)
        AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    }

    private func startDiagnosticsTimer() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 2, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self else {
                return
            }

            NSLog(
                "Xavucontrol virtual cable route %@ -> %@ captured=%llu played=%llu buffered=%d underflows=%llu skipped=%llu write=%llu read=%llu audioFrames=%llu driverFrames=%llu peak=%.5f rms=%.5f requestedUID=%@ actualUID=%@",
                self.appName,
                self.targetDeviceName,
                self.capturedBytes,
                self.playedBytes,
                self.ringBuffer.availableBytes,
                self.underflowCount,
                self.skippedBytes,
                self.readUInt64(offset: 176),
                self.readBytePosition,
                self.readUInt64(offset: 184),
                self.readUInt64(offset: 16),
                self.readFloat32(offset: 24),
                self.readFloat32(offset: 28),
                self.requestedOutputDeviceUID,
                self.actualOutputDeviceUID
            )
        }
        diagnosticsTimer = timer
        timer.resume()
    }

    private func readUInt32(offset: Int) -> UInt32 {
        guard let sharedPointer else {
            return 0
        }

        return sharedPointer.advanced(by: offset).assumingMemoryBound(to: UInt32.self).pointee
    }

    private func readUInt64(offset: Int) -> UInt64 {
        guard let sharedPointer else {
            return 0
        }

        return sharedPointer.advanced(by: offset).assumingMemoryBound(to: UInt64.self).pointee
    }

    private func readFloat64(offset: Int) -> Float64 {
        guard let sharedPointer else {
            return 48_000
        }

        let sampleRate = sharedPointer.advanced(by: offset).assumingMemoryBound(to: Float64.self).pointee
        return sampleRate > 0 ? sampleRate : 48_000
    }

    private func readFloat32(offset: Int) -> Float32 {
        guard let sharedPointer else {
            return 0
        }

        return sharedPointer.advanced(by: offset).assumingMemoryBound(to: Float32.self).pointee
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
        }, "Read virtual cable target device UID")
        return value as String
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

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw VirtualCableRouteError(message: "\(operation) failed: \(VirtualCableRouteSession.describe(status: status))")
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

private nonisolated final class VirtualCableByteRingBuffer {
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

nonisolated private let virtualCableOutputProc: AudioQueueOutputCallback = { clientData, queue, buffer in
    guard let clientData else {
        return
    }

    let session = Unmanaged<VirtualCableRouteSession>.fromOpaque(clientData).takeUnretainedValue()
    session.handleOutputBuffer(queue: queue, buffer: buffer)
}
