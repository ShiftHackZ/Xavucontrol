import SwiftUI

struct MainWindow: View {
    var body: some View {
        TabView {
            StreamsTab(direction: .playback)
                .tabItem { Text("Playback") }

            StreamsTab(direction: .recording)
                .tabItem { Text("Recording") }

            DevicesTab(kind: .output)
                .tabItem { Text("Output Devices") }

            DevicesTab(kind: .input)
                .tabItem { Text("Input Devices") }

            PatchbayTab()
                .tabItem { Text("Patchbay") }

            SetupTab()
                .tabItem { Text("Setup") }
        }
        .padding(12)
        .background(WindowCloseHider())
    }
}
