import SwiftUI

struct DevicesTab: View {
    @EnvironmentObject private var audioModel: AudioModel
    @State private var showFilter: DeviceShowFilter = .hardwareDevices

    let kind: DeviceKind

    private var devices: Binding<[AudioDevice]> {
        switch kind {
        case .output: $audioModel.outputDevices
        case .input: $audioModel.inputDevices
        }
    }

    private var filteredDevices: [Binding<AudioDevice>] {
        devices.filter { $device in
            switch showFilter {
            case .allDevices:
                return true
            case .hardwareDevices:
                return !device.isXavucontrolTapDevice
            case .virtualDevices:
                return device.isXavucontrolTapDevice
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DiscoveryBar()
            FilterBar(selection: $showFilter)

            if filteredDevices.isEmpty {
                EmptyState(title: "No Core Audio devices", detail: audioModel.deviceDiscoveryStatus)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(filteredDevices) { $device in
                            DeviceRow(device: $device, kind: kind)
                        }
                    }
                    .padding(.trailing, 4)
                }
            }
        }
    }
}

struct DeviceRow: View {
    @EnvironmentObject private var audioModel: AudioModel
    @Binding var device: AudioDevice
    let kind: DeviceKind

    private var muteBinding: Binding<Bool> {
        Binding(
            get: { device.isMuted },
            set: { audioModel.updateDeviceMuted(deviceID: device.id, kind: kind, isMuted: $0) }
        )
    }

    private var volumeBinding: Binding<Double> {
        Binding(
            get: { device.volume },
            set: { audioModel.updateDeviceVolume(deviceID: device.id, kind: kind, volume: $0) }
        )
    }

    private var showsDeviceControls: Bool {
        !device.isXavucontrolTapDevice
    }

    private var showsLevelControls: Bool {
        !device.isXavucontrolVirtualDevice
    }

    private var showsInputMonitorControls: Bool {
        kind == .input && showsLevelControls
    }

    private var monitorOutputs: [AudioDevice] {
        audioModel.outputDevices.filter { !$0.isXavucontrolVirtualDevice }
    }

    private var inputMonitorSelection: Binding<String> {
        Binding(
            get: { audioModel.inputMonitorOutputDeviceID(for: device.id) ?? "" },
            set: { outputDeviceID in
                audioModel.setInputMonitorOutputDeviceID(
                    inputDeviceID: device.id,
                    outputDeviceID: outputDeviceID.isEmpty ? nil : outputDeviceID
                )
            }
        )
    }

    private var channelSummary: String {
        let count = device.channels.count
        switch (kind, count) {
        case (.output, 1):
            return "1 output channel"
        case (.input, 1):
            return "1 input channel"
        case (.output, _):
            return "\(count) output channels"
        case (.input, _):
            return "\(count) input channels"
        }
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    IconTile(systemName: device.iconName)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(device.name)
                                .font(.headline)
                            if device.isDefault {
                                Text("system default")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                            }
                            if kind == .output && isApplicationDefault(device) {
                                Text("app default")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                            }
                        }
                        Text(device.description)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if showsDeviceControls {
                        VStack(alignment: .trailing, spacing: 6) {
                            if showsLevelControls && device.supportsMute {
                                Toggle("Mute", isOn: muteBinding)
                                    .toggleStyle(.checkbox)
                            }

                            if kind == .output {
                                Button {
                                    audioModel.setSystemDefaultDevice(deviceID: device.id, kind: kind)
                                } label: {
                                    Label("Use as System Default", systemImage: kind.systemDefaultIconName)
                                }
                                .disabled(device.isDefault)

                                if showsLevelControls {
                                    Button {
                                        setApplicationDefault(device)
                                    } label: {
                                        Label("Use as App Default", systemImage: "checkmark.circle")
                                    }
                                    .disabled(isApplicationDefault(device))
                                }
                            } else {
                                if showsLevelControls {
                                    Toggle(
                                        "To Virtual Mic",
                                        isOn: Binding(
                                            get: { audioModel.isInputDeviceIncludedInVirtualMic(deviceID: device.id) },
                                            set: { audioModel.setInputDeviceIncludedInVirtualMic(deviceID: device.id, isIncluded: $0) }
                                        )
                                    )
                                    .toggleStyle(.checkbox)
                                }

                                Button {
                                    audioModel.setSystemDefaultDevice(deviceID: device.id, kind: kind)
                                } label: {
                                    Label("Use as System Default", systemImage: kind.systemDefaultIconName)
                                }
                                .disabled(device.isDefault)
                            }
                        }
                        .controlSize(.small)
                    }
                }

                if showsLevelControls {
                    controlSummary
                        .padding(.leading, 52)
                } else {
                    Text("Virtual routing device; volume and mute are controlled per stream.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 52)
                }

            }
            .padding(.vertical, 4)
        }
    }

    private func isApplicationDefault(_ device: AudioDevice) -> Bool {
        switch kind {
        case .output:
            return audioModel.isApplicationDefaultOutputDevice(device)
        case .input:
            return audioModel.isApplicationDefaultInputDevice(device)
        }
    }

    private func setApplicationDefault(_ device: AudioDevice) {
        switch kind {
        case .output:
            audioModel.setApplicationDefaultOutputDevice(deviceID: device.id)
        case .input:
            audioModel.setApplicationDefaultInputDevice(deviceID: device.id)
        }
    }

    @ViewBuilder
    private var controlSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            if device.supportsVolume {
                VolumeControl(
                    title: kind.volumeLabel,
                    volume: volumeBinding,
                    isMuted: muteBinding,
                    isLocked: .constant(true),
                    showsLock: false
                )
            } else {
                HStack(spacing: 8) {
                    Text(kind.volumeLabel)
                        .frame(width: 112, alignment: .trailing)
                    Text("Not controllable by macOS")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            HStack(spacing: 8) {
                Text("Channels:")
                    .frame(width: 112, alignment: .trailing)
                Text(channelSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if !device.supportsMute {
                HStack(spacing: 8) {
                    Text("Mute:")
                        .frame(width: 112, alignment: .trailing)
                    Text("Not controllable by macOS")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            if showsInputMonitorControls {
                HStack(spacing: 8) {
                    Text("Listen On:")
                        .frame(width: 112, alignment: .trailing)
                    Picker("", selection: inputMonitorSelection) {
                        Text("-").tag("")
                        ForEach(monitorOutputs) { output in
                            Text(output.name).tag(output.id)
                        }
                    }
                    .labelsHidden()
                    Spacer()
                }
            }
        }
    }
}

private extension DeviceKind {
    var systemDefaultIconName: String {
        switch self {
        case .output: "speaker.wave.2.circle"
        case .input: "mic.circle"
        }
    }
}
