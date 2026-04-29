import SwiftUI

struct SetupTab: View {
    @EnvironmentObject private var audioModel: AudioModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DiscoveryBar()

            HStack(spacing: 8) {
                Button {
                    audioModel.installVirtualCable()
                } label: {
                    Label(
                        audioModel.setupState.isInstalling ? "Installing..." : "Install Virtual Cable",
                        systemImage: "square.and.arrow.down"
                    )
                }
                .disabled(audioModel.setupState.isInstalling)

                Button {
                    audioModel.uninstallVirtualCable()
                } label: {
                    Label("Remove Virtual Cable", systemImage: "trash")
                }
                .disabled(audioModel.setupState.isInstalling)

                Button {
                    audioModel.makeVirtualCableDefault()
                } label: {
                    Label("Make System Default", systemImage: "speaker.wave.2.circle")
                }
                .disabled(audioModel.setupState.virtualCableOutputID == nil && audioModel.setupState.virtualCableInputID == nil)

                Button {
                    audioModel.refreshDevices()
                    audioModel.refreshSetupDiagnostics()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }

                Button {
                    audioModel.probeVirtualCableIO()
                } label: {
                    Label("Probe Driver IO", systemImage: "waveform.path")
                }
                .disabled(audioModel.setupState.virtualCableOutputID == nil)

                Button {
                    audioModel.requestMicrophoneAccess()
                } label: {
                    Label("Request Mic Access", systemImage: "mic.badge.plus")
                }

                Button {
                    audioModel.resetPreferences()
                } label: {
                    Label("Clear Preferences", systemImage: "eraser")
                }

                Spacer()
            }
            .controlSize(.small)

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        IconTile(systemName: "cable.connector")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(SetupState.virtualCableName)
                                .font(.headline)
                            Text(audioModel.setupState.installStatus)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Text(audioModel.setupState.defaultDeviceStatus)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Text(audioModel.setupState.bundledDriverStatus)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Text(audioModel.setupState.microphoneAccessStatus)
                                .font(.callout)
                                .foregroundStyle(.secondary)

                            Toggle(
                                "Launch Xavucontrol at Login",
                                isOn: Binding(
                                    get: { audioModel.launchAtLoginEnabled },
                                    set: { audioModel.setLaunchAtLogin($0) }
                                )
                            )
                            .toggleStyle(.checkbox)
                            .controlSize(.small)
                            .padding(.top, 4)

                            Text(audioModel.launchAtLoginStatus)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                .padding(.vertical, 4)
            }

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(audioModel.setupState.diagnostics) { item in
                        SetupDiagnosticRow(item: item)
                    }
                }
                .padding(.trailing, 4)
            }
        }
    }
}

struct SetupDiagnosticRow: View {
    let item: SetupDiagnosticItem

    var body: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: item.state.iconName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(iconStyle)
                    .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.headline)
                    Text(item.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.vertical, 4)
        }
    }

    private var iconStyle: Color {
        switch item.state {
        case .ready:
            return .green
        case .warning:
            return .orange
        case .missing:
            return .red
        case .blocked:
            return .secondary
        }
    }
}
