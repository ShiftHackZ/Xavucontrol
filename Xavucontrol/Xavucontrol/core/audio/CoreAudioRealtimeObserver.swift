import CoreAudio
import Foundation

final class CoreAudioRealtimeObserver {
    private let queue = DispatchQueue(label: "org.moroz.xavucontrol.core-audio-observer")
    private let callbackQueue = DispatchQueue.main
    private let onDevicesChanged: @MainActor () -> Void
    private let onProcessesChanged: @MainActor () -> Void
    private let processProvider = AudioProcessProvider()

    private var isStarted = false
    private var observedProcesses = Set<AudioObjectID>()
    private var pendingDeviceRefresh: DispatchWorkItem?
    private var pendingProcessRefresh: DispatchWorkItem?

    private lazy var devicesChangedBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.scheduleDeviceRefresh()
    }

    private lazy var processesChangedBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.scheduleProcessRefresh()
    }

    init(
        onDevicesChanged: @escaping @MainActor () -> Void,
        onProcessesChanged: @escaping @MainActor () -> Void
    ) {
        self.onDevicesChanged = onDevicesChanged
        self.onProcessesChanged = onProcessesChanged
    }

    deinit {
        stop()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        addSystemListener(selector: kAudioHardwarePropertyDevices, block: devicesChangedBlock)
        addSystemListener(selector: kAudioHardwarePropertyDefaultOutputDevice, block: devicesChangedBlock)
        addSystemListener(selector: kAudioHardwarePropertyDefaultInputDevice, block: devicesChangedBlock)
        addSystemListener(selector: kAudioHardwarePropertyProcessObjectList, block: processesChangedBlock)
        queue.async { [weak self] in
            self?.refreshProcessListeners()
        }
    }

    func stop() {
        guard isStarted else { return }

        removeSystemListener(selector: kAudioHardwarePropertyDevices, block: devicesChangedBlock)
        removeSystemListener(selector: kAudioHardwarePropertyDefaultOutputDevice, block: devicesChangedBlock)
        removeSystemListener(selector: kAudioHardwarePropertyDefaultInputDevice, block: devicesChangedBlock)
        removeSystemListener(selector: kAudioHardwarePropertyProcessObjectList, block: processesChangedBlock)

        for processObjectID in observedProcesses {
            removeProcessListeners(processObjectID: processObjectID)
        }
        observedProcesses.removeAll()

        pendingDeviceRefresh?.cancel()
        pendingProcessRefresh?.cancel()
        isStarted = false
    }

    func refreshProcessListeners() {
        let currentProcesses = Set(processProvider.loadProcessObjectIDs())
        let addedProcesses = currentProcesses.subtracting(observedProcesses)
        let removedProcesses = observedProcesses.subtracting(currentProcesses)

        for processObjectID in removedProcesses {
            removeProcessListeners(processObjectID: processObjectID)
        }

        for processObjectID in addedProcesses {
            addProcessListeners(processObjectID: processObjectID)
        }

        observedProcesses = currentProcesses
    }
}

private extension CoreAudioRealtimeObserver {
    func scheduleDeviceRefresh() {
        pendingDeviceRefresh?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.onDevicesChanged()
            }
        }
        pendingDeviceRefresh = workItem
        callbackQueue.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    func scheduleProcessRefresh() {
        pendingProcessRefresh?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.refreshProcessListeners()
            Task { @MainActor in
                self.onProcessesChanged()
            }
        }
        pendingProcessRefresh = workItem
        callbackQueue.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    func addSystemListener(selector: AudioObjectPropertySelector, block: @escaping AudioObjectPropertyListenerBlock) {
        var address = systemAddress(selector: selector)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
    }

    func removeSystemListener(selector: AudioObjectPropertySelector, block: @escaping AudioObjectPropertyListenerBlock) {
        var address = systemAddress(selector: selector)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
    }

    func addProcessListeners(processObjectID: AudioObjectID) {
        addProcessListener(processObjectID: processObjectID, selector: kAudioProcessPropertyIsRunning)
        addProcessListener(processObjectID: processObjectID, selector: kAudioProcessPropertyIsRunningInput)
        addProcessListener(processObjectID: processObjectID, selector: kAudioProcessPropertyIsRunningOutput)
        addProcessListener(processObjectID: processObjectID, selector: kAudioProcessPropertyDevices, scope: kAudioDevicePropertyScopeInput)
        addProcessListener(processObjectID: processObjectID, selector: kAudioProcessPropertyDevices, scope: kAudioDevicePropertyScopeOutput)
    }

    func removeProcessListeners(processObjectID: AudioObjectID) {
        removeProcessListener(processObjectID: processObjectID, selector: kAudioProcessPropertyIsRunning)
        removeProcessListener(processObjectID: processObjectID, selector: kAudioProcessPropertyIsRunningInput)
        removeProcessListener(processObjectID: processObjectID, selector: kAudioProcessPropertyIsRunningOutput)
        removeProcessListener(processObjectID: processObjectID, selector: kAudioProcessPropertyDevices, scope: kAudioDevicePropertyScopeInput)
        removeProcessListener(processObjectID: processObjectID, selector: kAudioProcessPropertyDevices, scope: kAudioDevicePropertyScopeOutput)
    }

    func addProcessListener(
        processObjectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(processObjectID, &address) else {
            return
        }

        AudioObjectAddPropertyListenerBlock(processObjectID, &address, queue, processesChangedBlock)
    }

    func removeProcessListener(
        processObjectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(processObjectID, &address) else {
            return
        }

        AudioObjectRemovePropertyListenerBlock(processObjectID, &address, queue, processesChangedBlock)
    }

    func systemAddress(selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
