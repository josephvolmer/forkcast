import AppKit
import SwiftUI

@main
struct ForkcastApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        AppModel.shared.start()
        if CommandLine.arguments.contains("--window") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { AppDelegate.showWindow() }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            CompactView()
        } label: {
            MenuLabel()
        }
        .menuBarExtraStyle(.window)
    }
}

/// Opening the app again (Finder, Spotlight, `open`) shows the full dashboard window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor private static var window: NSWindow?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { Self.showWindow() }
        return false
    }

    @MainActor static func showWindow() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 900),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "Forkcast"
            w.contentView = NSHostingView(rootView: Dashboard())
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("ForkcastDashboard")
            if w.frame.width < 1180 { w.setContentSize(NSSize(width: 1360, height: 900)) }
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Menu bar: just the fork (a template image, so macOS tints it for light and dark menu bars).
struct MenuLabel: View {
    var body: some View { Image(nsImage: Icons.menuFork) }
}
