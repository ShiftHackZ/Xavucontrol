import SwiftUI

struct VolumeControl: View {
    let title: String
    @Binding var volume: Double
    @Binding var isMuted: Bool
    @Binding var isLocked: Bool
    let showsLock: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.callout)
                .frame(width: 112, alignment: .trailing)

            Button {
                isMuted.toggle()
            } label: {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .help(isMuted ? "Unmute" : "Mute")

            Slider(value: $volume, in: 0...1)
                .frame(minWidth: 240)

            Text("\(Int(volume * 100))%")
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)

            if showsLock {
                Button {
                    isLocked.toggle()
                } label: {
                    Image(systemName: isLocked ? "lock.fill" : "lock.open.fill")
                        .frame(width: 18)
                }
                .buttonStyle(.borderless)
                .help(isLocked ? "Unlock channels" : "Lock channels")
            }
        }
        .controlSize(.small)
    }
}

struct ChannelSlider: View {
    @Binding var channel: AudioChannel

    var body: some View {
        HStack(spacing: 8) {
            Text(channel.name)
                .frame(width: 112, alignment: .trailing)
            Slider(value: $channel.volume, in: 0...1)
                .frame(minWidth: 240)
            Text("\(Int(channel.volume * 100))%")
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)
            Spacer(minLength: 26)
        }
        .controlSize(.small)
    }
}
