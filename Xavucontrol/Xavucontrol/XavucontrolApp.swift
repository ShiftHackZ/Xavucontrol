import AppKit
import SwiftUI

final class XavucontrolAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .showXavucontrolMainWindow, object: nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct XavucontrolApp: App {
    @NSApplicationDelegateAdaptor(XavucontrolAppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @StateObject private var audioModel = AudioModel()

    var body: some Scene {
        Window("Xavucontrol", id: "main") {
            MainWindow()
                .environmentObject(audioModel)
                .frame(minWidth: 860, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra("Xavucontrol", systemImage: "slider.horizontal.3") {
            Button("Show Xavucontrol") {
                showMainWindow()
            }
            .keyboardShortcut("0")

            Divider()

            Button("Quit Xavucontrol") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    private func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "main")
        NotificationCenter.default.post(name: .showXavucontrolMainWindow, object: nil)

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .showXavucontrolMainWindow, object: nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
