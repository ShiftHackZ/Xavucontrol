import SwiftUI

struct DiscoveryBar: View {
    @EnvironmentObject private var audioModel: AudioModel

    var body: some View {
        HStack(spacing: 8) {
            Text(audioModel.deviceDiscoveryStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(audioModel.realtimeStatus)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                audioModel.refreshDevices()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
        }
    }
}

struct StreamDiscoveryBar: View {
    @EnvironmentObject private var audioModel: AudioModel

    var body: some View {
        HStack(spacing: 8) {
            Text(audioModel.streamDiscoveryStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(audioModel.routingStatus)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                audioModel.refreshStreams()
            } label: {
                Label("Refresh Streams", systemImage: "arrow.triangle.2.circlepath")
            }
            .controlSize(.small)
        }
    }
}
