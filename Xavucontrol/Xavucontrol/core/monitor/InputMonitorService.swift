import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

actor InputMonitorService {
    static let shared = InputMonitorService()

    private var sessions: [AudioDevice.ID: InputMonitorSession] = [:]

    func setMonitor(inputDevice: AudioDevice, outputDevice: AudioDevice?) async throws -> String {
        sessions[inputDevice.id]?.stop()
        sessions.removeValue(forKey: inputDevice.id)

        guard let outputDevice else {
            return "Input monitor disabled for \(inputDevice.name)"
        }

        try await ensureMicrophoneAccess()
        guard let inputObjectID = inputDevice.coreAudioObjectID,
              let outputObjectID = outputDevice.coreAudioObjectID else {
            throw VirtualMicrophoneRouteError(message: "Input monitor requires Core Audio object IDs")
        }

        let session = InputMonitorSession(
            inputDeviceID: inputObjectID,
            inputDeviceName: inputDevice.name,
            outputDeviceID: outputObjectID,
            outputDeviceName: outputDevice.name
        )
        try session.start()
        sessions[inputDevice.id] = session
        return "Listening to \(inputDevice.name) on \(outputDevice.name)"
    }

    func reconcile(inputDevices: [AudioDevice], outputDevices: [AudioDevice], routes: [AudioDevice.ID: AudioDevice.ID]) async -> String {
        var activeInputIDs = Set<AudioDevice.ID>()
        var messages: [String] = []

        for (inputID, outputID) in routes {
            guard let inputDevice = inputDevices.first(where: { $0.id == inputID && !$0.isXavucontrolVirtualDevice }),
                  let outputDevice = outputDevices.first(where: { $0.id == outputID && !$0.isXavucontrolVirtualDevice }) else {
                sessions[inputID]?.stop()
                sessions.removeValue(forKey: inputID)
                continue
            }

            activeInputIDs.insert(inputID)
            if sessions[inputID]?.matches(inputDeviceID: inputDevice.coreAudioObjectID, outputDeviceID: outputDevice.coreAudioObjectID) == true {
                continue
            }

            do {
                let message = try await setMonitor(inputDevice: inputDevice, outputDevice: outputDevice)
                messages.append(message)
            } catch {
                messages.append(error.localizedDescription)
            }
        }

        for inputID in sessions.keys where !activeInputIDs.contains(inputID) {
            sessions[inputID]?.stop()
            sessions.removeValue(forKey: inputID)
        }

        return messages.last ?? "Input monitors updated"
    }

    func stopAll() {
        sessions.values.forEach { $0.stop() }
        sessions.removeAll()
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

private nonisolated final class InputMonitorSession {
    private let inputDeviceID: AudioObjectID
    private let inputDeviceName: String
    private let outputDeviceID: AudioObjectID
    private let outputDeviceName: String
    private let ringBuffer = InputMonitorFloatRingBuffer(capacity: 48_000 * 4)

    private var inputQueue: AudioQueueRef?
    private var outputQueue: AudioQueueRef?
    private var inputBuffers: [AudioQueueBufferRef] = []
    private var outputBuffers: [AudioQueueBufferRef] = []
    private var capturedBytes: UInt64 = 0
    private var playedBytes: UInt64 = 0
    private var emptyOutputCallbacks: UInt64 = 0
    private var lastLogTime = DispatchTime.now().uptimeNanoseconds

    init(inputDeviceID: AudioObjectID, inputDeviceName: String, outputDeviceID: AudioObjectID, outputDeviceName: String) {
        self.inputDeviceID = inputDeviceID
        self.inputDeviceName = inputDeviceName
        self.outputDeviceID = outputDeviceID
        self.outputDeviceName = outputDeviceName
    }

    deinit {
        stop()
    }

    func matches(inputDeviceID: AudioObjectID?, outputDeviceID: AudioObjectID?) -> Bool {
        self.inputDeviceID == inputDeviceID && self.outputDeviceID == outputDeviceID
    }

    func start() throws {
        var format = Self.monitorFormat(sampleRate: 48_000)
        try startInputQueue(format: &format)
        try startOutputQueue(format: &format)
        NSLog("Xavucontrol input monitor active %@ -> %@", inputDeviceName, outputDeviceName)
    }

    func stop() {
        if let inputQueue {
            AudioQueueStop(inputQueue, true)
            AudioQueueDispose(inputQueue, true)
            self.inputQueue = nil
        }
        if let outputQueue {
            AudioQueueStop(outputQueue, true)
            AudioQueueDispose(outputQueue, true)
            self.outputQueue = nil
        }
        inputBuffers.removeAll()
        outputBuffers.removeAll()
    }

    fileprivate func handleInputBuffer(queue: AudioQueueRef, buffer: AudioQueueBufferRef) {
        let byteCount = Int(buffer.pointee.mAudioDataByteSize)
        if byteCount > 0 {
            ringBuffer.write(
                samples: buffer.pointee.mAudioData.assumingMemoryBound(to: Float32.self),
                count: byteCount / MemoryLayout<Float32>.size
            )
            capturedBytes &+= UInt64(byteCount)
        }
        AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
    }

    fileprivate func fillOutputBuffer(_ buffer: AudioQueueBufferRef) {
        let sampleCount = Int(buffer.pointee.mAudioDataBytesCapacity) / MemoryLayout<Float32>.size
        let samplesRead = ringBuffer.read(into: buffer.pointee.mAudioData.assumingMemoryBound(to: Float32.self), count: sampleCount)
        if samplesRead == 0 {
            emptyOutputCallbacks &+= 1
        }
        playedBytes &+= UInt64(sampleCount * MemoryLayout<Float32>.size)
        buffer.pointee.mAudioDataByteSize = buffer.pointee.mAudioDataBytesCapacity
        logIfNeeded()
        if let outputQueue {
            AudioQueueEnqueueBuffer(outputQueue, buffer, 0, nil)
        }
    }

    private func startInputQueue(format: inout AudioStreamBasicDescription) throws {
        var queue: AudioQueueRef?
        let context = Unmanaged.passUnretained(self).toOpaque()
        try check(AudioQueueNewInput(&format, inputMonitorInputProc, context, nil, nil, 0, &queue), "Create input monitor input queue")
        guard let queue else {
            throw VirtualMicrophoneRouteError(message: "Input monitor input queue could not be created")
        }

        let uid = try readDeviceUID(deviceID: inputDeviceID)
        try setQueueCurrentDevice(queue, uid: uid, operation: "Set input monitor source device")

        let bufferByteSize = UInt32(Int(format.mBytesPerFrame) * 1024)
        for _ in 0..<4 {
            var buffer: AudioQueueBufferRef?
            try check(AudioQueueAllocateBuffer(queue, bufferByteSize, &buffer), "Allocate input monitor input buffer")
            guard let buffer else { continue }
            inputBuffers.append(buffer)
            try check(AudioQueueEnqueueBuffer(queue, buffer, 0, nil), "Prime input monitor input buffer")
        }

        inputQueue = queue
        try check(AudioQueueStart(queue, nil), "Start input monitor input queue")
    }

    private func startOutputQueue(format: inout AudioStreamBasicDescription) throws {
        var queue: AudioQueueRef?
        let context = Unmanaged.passUnretained(self).toOpaque()
        try check(AudioQueueNewOutput(&format, inputMonitorOutputProc, context, nil, nil, 0, &queue), "Create input monitor output queue")
        guard let queue else {
            throw VirtualMicrophoneRouteError(message: "Input monitor output queue could not be created")
        }

        let uid = try readDeviceUID(deviceID: outputDeviceID)
        try setQueueCurrentDevice(queue, uid: uid, operation: "Set input monitor output device")
        AudioQueueSetParameter(queue, kAudioQueueParam_Volume, 1.0)

        outputQueue = queue
        let bufferByteSize = UInt32(Int(format.mBytesPerFrame) * 1024)
        for _ in 0..<4 {
            var buffer: AudioQueueBufferRef?
            try check(AudioQueueAllocateBuffer(queue, bufferByteSize, &buffer), "Allocate input monitor output buffer")
            guard let buffer else { continue }
            outputBuffers.append(buffer)
            fillOutputBuffer(buffer)
        }

        try check(AudioQueueStart(queue, nil), "Start input monitor output queue")
    }

    private func logIfNeeded() {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now - lastLogTime >= 1_000_000_000 else {
            return
        }
        lastLogTime = now
        NSLog(
            "Xavucontrol input monitor %@ -> %@ captured=%llu played=%llu empty=%llu bufferedSamples=%d",
            inputDeviceName,
            outputDeviceName,
            capturedBytes,
            playedBytes,
            emptyOutputCallbacks,
            ringBuffer.availableSamples
        )
    }

    private static func monitorFormat(sampleRate: Float64) -> AudioStreamBasicDescription {
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

    private func setQueueCurrentDevice(_ queue: AudioQueueRef, uid: String, operation: String) throws {
        var uid = uid as CFString
        try check(withUnsafePointer(to: &uid) { pointer in
            AudioQueueSetProperty(queue, kAudioQueueProperty_CurrentDevice, pointer, UInt32(MemoryLayout<CFString>.size))
        }, operation)
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
        }, "Read input monitor device UID")
        return value as String
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw VirtualMicrophoneRouteError(message: "\(operation) failed: \(status)")
        }
    }
}

private nonisolated final class InputMonitorFloatRingBuffer {
    private let lock = NSLock()
    private var storage: [Float32]
    private var readIndex = 0
    private var writeIndex = 0
    private var available = 0

    init(capacity: Int) {
        storage = Array(repeating: 0, count: max(capacity, 1))
    }

    func write(samples: UnsafePointer<Float32>, count: Int) {
        guard count > 0 else { return }
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

    var availableSamples: Int {
        lock.lock()
        defer { lock.unlock() }
        return available
    }

    @discardableResult
    func read(into destination: UnsafeMutablePointer<Float32>, count: Int) -> Int {
        guard count > 0 else { return 0 }
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
        return samplesToRead
    }
}

nonisolated private let inputMonitorInputProc: AudioQueueInputCallback = { clientData, queue, buffer, _, _, _ in
    guard let clientData else { return }
    let session = Unmanaged<InputMonitorSession>.fromOpaque(clientData).takeUnretainedValue()
    session.handleInputBuffer(queue: queue, buffer: buffer)
}

nonisolated private let inputMonitorOutputProc: AudioQueueOutputCallback = { clientData, _, buffer in
    guard let clientData else { return }
    let session = Unmanaged<InputMonitorSession>.fromOpaque(clientData).takeUnretainedValue()
    session.fillOutputBuffer(buffer)
}
