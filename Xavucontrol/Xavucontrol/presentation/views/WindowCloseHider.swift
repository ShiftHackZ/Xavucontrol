import AppKit
import SwiftUI

extension Notification.Name {
    static let showXavucontrolMainWindow = Notification.Name("org.moroz.xavucontrol.show-main-window")
}

struct WindowCloseHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            context.coordinator.attach(window: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.attach(window: nsView.window)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        private weak var window: NSWindow?
        private var observer: NSObjectProtocol?

        override init() {
            super.init()
            observer = NotificationCenter.default.addObserver(
                forName: .showXavucontrolMainWindow,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.showWindow()
            }
        }

        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        func attach(window: NSWindow?) {
            guard let window else { return }
            self.window = window
            window.delegate = self
            window.isReleasedWhenClosed = false
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            sender.orderOut(nil)
            NSApp.setActivationPolicy(.accessory)
            return false
        }

        private func showWindow() {
            guard let window else { return }
            NSApp.setActivationPolicy(.regular)
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
