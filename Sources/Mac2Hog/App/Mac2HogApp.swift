#if os(macOS)
import SwiftUI
import AppKit
import Mac2HogCore

@main
struct Mac2HogApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup("Mac2Hog") {
            ContentView()
                .environmentObject(state)
                .environmentObject(state.playback)
                .frame(minWidth: 1100, minHeight: 720)
        }
        .commands { AppCommands(state: state, playback: state.playback) }

        Settings {
            SettingsView()
                .environmentObject(state)
                .environmentObject(state.playback)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched from `swift run` (no bundle): become a regular foreground app.
        NSApp.setActivationPolicy(.regular)
        // Inside Mac2Hog.app macOS uses the bundled icon; when unbundled, set it ourselves.
        if Bundle.main.bundleURL.pathExtension != "app",
           let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = image
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
#else
@main
enum Mac2HogApp {
    static func main() {
        print("Mac2Hog is a macOS application. On this platform only the Mac2HogCore engine is available (run `swift test`).")
    }
}
#endif
