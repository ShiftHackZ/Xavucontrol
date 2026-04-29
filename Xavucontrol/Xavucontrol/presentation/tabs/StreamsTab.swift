import AppKit
import SwiftUI

struct StreamsTab: View {
    @EnvironmentObject private var audioModel: AudioModel
    @State private var showFilter: ShowFilter = .applications

    let direction: StreamDirection

    private var devices: [AudioDevice] {
        switch direction {
        case .playback:
            return audioModel.outputDevices.filter { !$0.isXavucontrolVirtualDevice }
        case .recording:
            return audioModel.inputDevices.filter { !$0.isXavucontrolVirtualDevice }
        }
    }

    private var streamBindings: [Binding<AppAudioStream>] {
        $audioModel.streams.filter { $stream in
            guard stream.direction == direction else {
                return false
            }

            switch showFilter {
            case .allStreams:
                return true
            case .applications:
                return !stream.isVirtualStream || stream.isInputMonitorStream
            case .virtualStreams:
                return stream.isVirtualStream && !stream.isInputMonitorStream
            }
        }
    }

    private var emptyTitle: String {
        switch (direction, showFilter) {
        case (.playback, .allStreams): "No active playback streams"
        case (.playback, .applications): "No active playback applications"
        case (.playback, .virtualStreams): "No active virtual playback streams"
        case (.recording, .allStreams): "No active recording streams"
        case (.recording, .applications): "No active recording applications"
        case (.recording, .virtualStreams): "No active virtual recording streams"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DiscoveryBar()
            StreamDiscoveryBar()
            FilterBar(selection: $showFilter)

            if streamBindings.isEmpty {
                EmptyState(title: emptyTitle, detail: audioModel.streamDiscoveryStatus)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(streamBindings) { $stream in
                            StreamRow(stream: $stream, devices: devices)
                        }
                    }
                    .padding(.trailing, 4)
                }
            }
        }
    }
}

struct StreamRow: View {
    @EnvironmentObject private var audioModel: AudioModel
    @Binding var stream: AppAudioStream
    let devices: [AudioDevice]

    private var showsStreamControls: Bool {
        !stream.isVirtualStream && stream.direction == .playback
    }

    private var canControlStream: Bool {
        showsStreamControls && audioModel.streamUsesXavucontrolVirtualDevice(stream)
    }

    private var routeSelections: [String] {
        audioModel.routeSelectionIDs(for: stream)
    }

    private var routeSummary: String {
        let names = routeSelections.compactMap { selectionID in
            devices.first(where: { $0.id == selectionID }).map(deviceTitle)
        }
        return names.isEmpty ? "No available output" : names.joined(separator: ", ")
    }

    private var muteBinding: Binding<Bool> {
        Binding(
            get: { stream.isMuted },
            set: { audioModel.updateStreamMuted(streamID: stream.id, isMuted: $0) }
        )
    }

    private var volumeBinding: Binding<Double> {
        Binding(
            get: { stream.volume },
            set: { audioModel.updateStreamVolume(streamID: stream.id, volume: $0) }
        )
    }

    private var virtualMicBinding: Binding<Bool> {
        Binding(
            get: { audioModel.isPlaybackStreamIncludedInVirtualMic(stream) },
            set: { audioModel.setPlaybackStreamIncludedInVirtualMic(streamID: stream.id, isIncluded: $0) }
        )
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    AppIconTile(stream: stream)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(stream.appName)
                            .font(.headline)
                        Text(stream.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if !stream.isVirtualStream {
                        VStack(alignment: .trailing, spacing: 6) {
                            if stream.direction == .playback {
                                Toggle("Mute", isOn: muteBinding)
                                    .toggleStyle(.checkbox)
                                    .disabled(!canControlStream)
                                Toggle("To Virtual Mic", isOn: virtualMicBinding)
                                    .toggleStyle(.checkbox)
                            }
                        }
                        .controlSize(.small)
                    }
                }

                HStack(spacing: 8) {
                    Text("currently on")
                        .foregroundStyle(.secondary)
                    Text(assignedDeviceName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(minWidth: 280, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
                    Spacer()
                }
                .padding(.leading, 52)

                if stream.direction == .playback {
                    HStack(spacing: 8) {
                        Text("Route to:")
                            .frame(width: 76, alignment: .trailing)
                        Menu {
                            ForEach(devices) { device in
                                Button {
                                    toggleOutputDevice(device.id)
                                } label: {
                                    let title = deviceTitle(device)
                                    if routeSelections.contains(device.id) {
                                        Label(title, systemImage: "checkmark")
                                    } else {
                                        Text(title)
                                    }
                                }
                            }
                        } label: {
                            Text(routeSummary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(minWidth: 280, alignment: .leading)
                        }
                        .menuStyle(.borderlessButton)
                        .frame(minWidth: 280)
                        .disabled(stream.isVirtualStream)
                        Text(stream.routingStatus ?? (stream.isVirtualStream ? "Diagnostic stream" : "No routing request"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Spacer()
                    }
                    .padding(.leading, 52)
                } else if let routingStatus = stream.routingStatus {
                    Text(routingStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 52)
                }

                if showsStreamControls {
                    VolumeControl(
                        title: "Volume:",
                        volume: volumeBinding,
                        isMuted: muteBinding,
                        isLocked: $stream.isLocked,
                        showsLock: false
                    )
                    .disabled(!canControlStream)
                    .padding(.leading, 52)
                    if !canControlStream {
                        Text("Volume and mute are available when the stream is currently on an Xavucontrol virtual device.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 52)
                    }
                } else if stream.isInputMonitorStream {
                    Text("Input monitor stream; choose its output on Input Devices.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 52)
                } else {
                    Text(stream.direction == .recording ? "Recording streams are read-only; choose sources on Input Devices." : "Diagnostic stream; volume and mute are not available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 52)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var assignedDeviceName: String {
        guard let assignedDeviceID = stream.assignedDeviceID else {
            return "Unknown device"
        }

        let allDevices = stream.direction == .playback ? audioModel.outputDevices : audioModel.inputDevices
        return allDevices.first(where: { $0.id == assignedDeviceID })?.name ?? "Unknown device"
    }

    private func toggleOutputDevice(_ deviceID: AudioDevice.ID) {
        guard !stream.isVirtualStream else {
            return
        }

        audioModel.togglePlaybackRouteTarget(
            preferenceKey: stream.preferenceKey,
            targetDeviceID: deviceID
        )
    }

    private func deviceTitle(_ device: AudioDevice) -> String {
        if audioModel.isApplicationDefaultOutputDevice(device) {
            return "\(device.name) (Xavucontrol Default Output)"
        }
        return device.name
    }
}

private struct AppIconTile: View {
    let stream: AppAudioStream

    private var appIcon: NSImage? {
        if let processID = stream.processID,
           let runningApp = NSRunningApplication(processIdentifier: processID),
           let icon = runningApp.icon {
            return icon
        }

        if let bundleID = stream.bundleID,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: appURL.path)
        }

        return nil
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)

            if let appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 30, height: 30)
            } else {
                Image(systemName: stream.iconName)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 40, height: 40)
    }
}
