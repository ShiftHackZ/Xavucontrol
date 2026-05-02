import Foundation

struct AppPreferences: Hashable {
    static let defaultOutputRouteID = "org.moroz.xavucontrol.route.default-output"
    static let defaultInputRouteID = "org.moroz.xavucontrol.route.default-input"

    var defaultOutputDeviceID: AudioDevice.ID?
    var defaultInputDeviceID: AudioDevice.ID?
    var streamOutputDeviceIDs: [String: AudioDevice.ID]
    var streamOutputTargetDeviceIDs: [String: [AudioDevice.ID]]
    var streamInputDeviceIDs: [String: AudioDevice.ID]
    var streamVolumes: [String: Double]
    var streamMutedStates: [String: Bool]
    var virtualMicInputDeviceIDs: Set<AudioDevice.ID>
    var virtualMicPlaybackStreamKeys: Set<String>
    var inputMonitorOutputDeviceIDs: [AudioDevice.ID: AudioDevice.ID]
}

struct AppPreferenceStore {
    private enum Key {
        static let defaultOutputDeviceID = "preferences.defaultOutputDeviceID"
        static let defaultInputDeviceID = "preferences.defaultInputDeviceID"
        static let streamOutputDeviceIDs = "preferences.streamOutputDeviceIDs"
        static let streamOutputTargetDeviceIDs = "preferences.streamOutputTargetDeviceIDs"
        static let streamInputDeviceIDs = "preferences.streamInputDeviceIDs"
        static let streamVolumes = "preferences.streamVolumes"
        static let streamMutedStates = "preferences.streamMutedStates"
        static let virtualMicInputDeviceIDs = "preferences.virtualMicInputDeviceIDs"
        static let virtualMicPlaybackStreamKeys = "preferences.virtualMicPlaybackStreamKeys"
        static let inputMonitorOutputDeviceIDs = "preferences.inputMonitorOutputDeviceIDs"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AppPreferences {
        let legacyOutputRoutes = defaults.dictionary(forKey: Key.streamOutputDeviceIDs) as? [String: String] ?? [:]
        var outputTargetRoutes = defaults.dictionary(forKey: Key.streamOutputTargetDeviceIDs) as? [String: [String]] ?? [:]
        for (preferenceKey, deviceID) in legacyOutputRoutes where outputTargetRoutes[preferenceKey] == nil {
            outputTargetRoutes[preferenceKey] = [deviceID]
        }

        return AppPreferences(
            defaultOutputDeviceID: defaults.string(forKey: Key.defaultOutputDeviceID),
            defaultInputDeviceID: defaults.string(forKey: Key.defaultInputDeviceID),
            streamOutputDeviceIDs: legacyOutputRoutes,
            streamOutputTargetDeviceIDs: outputTargetRoutes,
            streamInputDeviceIDs: defaults.dictionary(forKey: Key.streamInputDeviceIDs) as? [String: String] ?? [:],
            streamVolumes: doubleDictionary(forKey: Key.streamVolumes),
            streamMutedStates: boolDictionary(forKey: Key.streamMutedStates),
            virtualMicInputDeviceIDs: Set(defaults.stringArray(forKey: Key.virtualMicInputDeviceIDs) ?? []),
            virtualMicPlaybackStreamKeys: Set(defaults.stringArray(forKey: Key.virtualMicPlaybackStreamKeys) ?? []),
            inputMonitorOutputDeviceIDs: defaults.dictionary(forKey: Key.inputMonitorOutputDeviceIDs) as? [String: String] ?? [:]
        )
    }

    func setDefaultOutputDeviceID(_ deviceID: AudioDevice.ID?) {
        if let deviceID {
            defaults.set(deviceID, forKey: Key.defaultOutputDeviceID)
        } else {
            defaults.removeObject(forKey: Key.defaultOutputDeviceID)
        }
    }

    func setDefaultInputDeviceID(_ deviceID: AudioDevice.ID?) {
        if let deviceID {
            defaults.set(deviceID, forKey: Key.defaultInputDeviceID)
        } else {
            defaults.removeObject(forKey: Key.defaultInputDeviceID)
        }
    }

    func setStreamOutputDeviceID(_ deviceID: AudioDevice.ID?, for preferenceKey: String) {
        var routes = defaults.dictionary(forKey: Key.streamOutputDeviceIDs) as? [String: String] ?? [:]
        if let deviceID {
            routes[preferenceKey] = deviceID
        } else {
            routes.removeValue(forKey: preferenceKey)
        }
        defaults.set(routes, forKey: Key.streamOutputDeviceIDs)
    }

    func setStreamOutputTargetDeviceIDs(_ deviceIDs: [AudioDevice.ID]?, for preferenceKey: String) {
        var routes = defaults.dictionary(forKey: Key.streamOutputTargetDeviceIDs) as? [String: [String]] ?? [:]
        if let deviceIDs, !deviceIDs.isEmpty {
            var uniqueDeviceIDs: [String] = []
            for deviceID in deviceIDs where !uniqueDeviceIDs.contains(deviceID) {
                uniqueDeviceIDs.append(deviceID)
            }
            routes[preferenceKey] = uniqueDeviceIDs
        } else {
            routes.removeValue(forKey: preferenceKey)
        }
        defaults.set(routes, forKey: Key.streamOutputTargetDeviceIDs)
    }

    func setStreamInputDeviceID(_ deviceID: AudioDevice.ID?, for preferenceKey: String) {
        var routes = defaults.dictionary(forKey: Key.streamInputDeviceIDs) as? [String: String] ?? [:]
        if let deviceID {
            routes[preferenceKey] = deviceID
        } else {
            routes.removeValue(forKey: preferenceKey)
        }
        defaults.set(routes, forKey: Key.streamInputDeviceIDs)
    }

    func setStreamVolume(_ volume: Double, for preferenceKey: String) {
        var volumes = doubleDictionary(forKey: Key.streamVolumes)
        volumes[preferenceKey] = max(0, min(1, volume))
        defaults.set(volumes, forKey: Key.streamVolumes)
    }

    func setStreamMuted(_ isMuted: Bool, for preferenceKey: String) {
        var mutedStates = boolDictionary(forKey: Key.streamMutedStates)
        mutedStates[preferenceKey] = isMuted
        defaults.set(mutedStates, forKey: Key.streamMutedStates)
    }

    func setVirtualMicInputDeviceEnabled(_ isEnabled: Bool, deviceID: AudioDevice.ID) {
        var deviceIDs = Set(defaults.stringArray(forKey: Key.virtualMicInputDeviceIDs) ?? [])
        if isEnabled {
            deviceIDs.insert(deviceID)
        } else {
            deviceIDs.remove(deviceID)
        }
        defaults.set(Array(deviceIDs).sorted(), forKey: Key.virtualMicInputDeviceIDs)
    }

    func setVirtualMicPlaybackStreamEnabled(_ isEnabled: Bool, preferenceKey: String) {
        var streamKeys = Set(defaults.stringArray(forKey: Key.virtualMicPlaybackStreamKeys) ?? [])
        if isEnabled {
            streamKeys.insert(preferenceKey)
        } else {
            streamKeys.remove(preferenceKey)
        }
        defaults.set(Array(streamKeys).sorted(), forKey: Key.virtualMicPlaybackStreamKeys)
    }

    func setInputMonitorOutputDeviceID(_ outputDeviceID: AudioDevice.ID?, inputDeviceID: AudioDevice.ID) {
        var routes = defaults.dictionary(forKey: Key.inputMonitorOutputDeviceIDs) as? [String: String] ?? [:]
        if let outputDeviceID {
            routes[inputDeviceID] = outputDeviceID
        } else {
            routes.removeValue(forKey: inputDeviceID)
        }
        defaults.set(routes, forKey: Key.inputMonitorOutputDeviceIDs)
    }

    func reset() {
        defaults.removeObject(forKey: Key.defaultOutputDeviceID)
        defaults.removeObject(forKey: Key.defaultInputDeviceID)
        defaults.removeObject(forKey: Key.streamOutputDeviceIDs)
        defaults.removeObject(forKey: Key.streamOutputTargetDeviceIDs)
        defaults.removeObject(forKey: Key.streamInputDeviceIDs)
        defaults.removeObject(forKey: Key.streamVolumes)
        defaults.removeObject(forKey: Key.streamMutedStates)
        defaults.removeObject(forKey: Key.virtualMicInputDeviceIDs)
        defaults.removeObject(forKey: Key.virtualMicPlaybackStreamKeys)
        defaults.removeObject(forKey: Key.inputMonitorOutputDeviceIDs)
    }

    private func doubleDictionary(forKey key: String) -> [String: Double] {
        let raw = defaults.dictionary(forKey: key) ?? [:]
        return raw.reduce(into: [String: Double]()) { result, entry in
            if let value = entry.value as? Double {
                result[entry.key] = value
            } else if let value = entry.value as? NSNumber {
                result[entry.key] = value.doubleValue
            }
        }
    }

    private func boolDictionary(forKey key: String) -> [String: Bool] {
        let raw = defaults.dictionary(forKey: key) ?? [:]
        return raw.reduce(into: [String: Bool]()) { result, entry in
            if let value = entry.value as? Bool {
                result[entry.key] = value
            } else if let value = entry.value as? NSNumber {
                result[entry.key] = value.boolValue
            }
        }
    }
}
