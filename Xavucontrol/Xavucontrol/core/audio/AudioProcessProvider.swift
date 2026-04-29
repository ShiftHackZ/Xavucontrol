import AppKit
import CoreAudio
import Foundation

struct AudioProcessProvider {
    func loadProcessObjectIDs() -> [AudioObjectID] {
        processObjectIDs()
    }

    func loadStreams(
        direction: StreamDirection,
        outputDevices: [AudioDevice],
        inputDevices: [AudioDevice]
    ) -> [AppAudioStream] {
        processObjectIDs().compactMap { processObjectID in
            guard isRunning(processObjectID: processObjectID, direction: direction) else {
                return nil
            }

            let pid = readPID(processObjectID: processObjectID)
            let bundleID = readBundleID(processObjectID: processObjectID)
            let isVirtualStream = pid == ProcessInfo.processInfo.processIdentifier || bundleID == Bundle.main.bundleIdentifier
            let deviceIDs = readDeviceIDs(processObjectID: processObjectID, direction: direction)
            let mappedDeviceID = mapFirstDeviceID(
                coreAudioDeviceIDs: deviceIDs,
                direction: direction,
                outputDevices: outputDevices,
                inputDevices: inputDevices
            )

            return AppAudioStream(
                id: "coreaudio-process-\(processObjectID)-\(direction.rawValue)",
                preferenceKey: preferenceKey(pid: pid, bundleID: bundleID),
                processID: pid,
                bundleID: bundleID,
                isVirtualStream: isVirtualStream,
                appName: displayName(pid: pid, bundleID: bundleID),
                detail: detail(pid: pid, bundleID: bundleID, processObjectID: processObjectID),
                iconName: iconName(direction: direction),
                direction: direction,
                volume: 1,
                isMuted: false,
                isLocked: true,
                assignedDeviceID: mappedDeviceID,
                requestedDeviceID: nil,
                routeSelectionID: nil,
                routingStatus: nil
            )
        }
        .sorted { lhs, rhs in
            lhs.appName.localizedCaseInsensitiveCompare(rhs.appName) == .orderedAscending
        }
    }
}

private extension AudioProcessProvider {
    func processObjectIDs() -> [AudioObjectID] {
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
        var processObjectIDs = Array(repeating: AudioObjectID(), count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &processObjectIDs) == noErr else {
            return []
        }

        return processObjectIDs.filter { $0 != kAudioObjectUnknown }
    }

    func isRunning(processObjectID: AudioObjectID, direction: StreamDirection) -> Bool {
        let selector: AudioObjectPropertySelector = switch direction {
        case .playback: kAudioProcessPropertyIsRunningOutput
        case .recording: kAudioProcessPropertyIsRunningInput
        }

        var address = AudioObjectPropertyAddress(
            mSelector: selector,
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

    func readPID(processObjectID: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(processObjectID, &address) else {
            return nil
        }

        var pid = pid_t()
        var dataSize = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(processObjectID, &address, 0, nil, &dataSize, &pid)
        guard status == noErr else {
            return nil
        }
        return pid
    }

    func readBundleID(processObjectID: AudioObjectID) -> String? {
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
        return value as String
    }

    func readDeviceIDs(processObjectID: AudioObjectID, direction: StreamDirection) -> [AudioObjectID] {
        let scope: AudioObjectPropertyScope = switch direction {
        case .playback: kAudioDevicePropertyScopeOutput
        case .recording: kAudioDevicePropertyScopeInput
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyDevices,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(processObjectID, &address, 0, nil, &dataSize) == noErr else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = Array(repeating: AudioObjectID(), count: count)
        guard AudioObjectGetPropertyData(processObjectID, &address, 0, nil, &dataSize, &deviceIDs) == noErr else {
            return []
        }
        return deviceIDs.filter { $0 != kAudioObjectUnknown }
    }

    func mapFirstDeviceID(
        coreAudioDeviceIDs: [AudioObjectID],
        direction: StreamDirection,
        outputDevices: [AudioDevice],
        inputDevices: [AudioDevice]
    ) -> AudioDevice.ID? {
        let devices = direction == .playback ? outputDevices : inputDevices
        for coreAudioDeviceID in coreAudioDeviceIDs {
            if let device = devices.first(where: { $0.coreAudioObjectID == coreAudioDeviceID }) {
                return device.id
            }
        }
        return devices.first(where: \.isDefault)?.id ?? devices.first?.id
    }

    func displayName(pid: pid_t?, bundleID: String?) -> String {
        if let pid,
           let runningApp = NSRunningApplication(processIdentifier: pid),
           let localizedName = runningApp.localizedName,
           !localizedName.isEmpty {
            return localizedName
        }

        if let bundleID, !bundleID.isEmpty {
            return bundleID
        }

        if let pid {
            return "Process \(pid)"
        }

        return "Audio Process"
    }

    func preferenceKey(pid: pid_t?, bundleID: String?) -> String {
        if let bundleID, !bundleID.isEmpty {
            return "bundle:\(bundleID)"
        }
        return "app:\(displayName(pid: pid, bundleID: bundleID))"
    }

    func detail(pid: pid_t?, bundleID: String?, processObjectID: AudioObjectID) -> String {
        var parts = ["Core Audio process \(processObjectID)"]
        if let pid {
            parts.append("PID \(pid)")
        }
        if let bundleID, !bundleID.isEmpty {
            parts.append(bundleID)
        }
        return parts.joined(separator: " - ")
    }

    func iconName(direction: StreamDirection) -> String {
        switch direction {
        case .playback: "speaker.wave.2.fill"
        case .recording: "mic.fill"
        }
    }
}
