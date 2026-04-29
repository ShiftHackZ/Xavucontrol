import SwiftUI

struct ConfigurationTab: View {
    @EnvironmentObject private var audioModel: AudioModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DiscoveryBar()

            if audioModel.profiles.isEmpty {
                EmptyState(title: "No Core Audio profiles", detail: "Core Audio did not expose any devices to configure.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach($audioModel.profiles) { $profile in
                            GroupBox {
                                HStack(alignment: .center, spacing: 12) {
                                    IconTile(systemName: "slider.horizontal.3")

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(profile.deviceName)
                                            .font(.headline)
                                        HStack {
                                            Text("Profile:")
                                                .foregroundStyle(.secondary)
                                            Picker("", selection: $profile.selectedProfile) {
                                                ForEach(profile.availableProfiles, id: \.self) { availableProfile in
                                                    Text(availableProfile).tag(availableProfile)
                                                }
                                            }
                                            .labelsHidden()
                                            .frame(width: 280)
                                        }
                                    }

                                    Spacer()
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                    .padding(.trailing, 4)
                }
            }
        }
    }
}
