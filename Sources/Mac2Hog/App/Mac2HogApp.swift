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
                .environmentObject(state.activity)
                .environmentObject(state.oscLog)
                .frame(minWidth: 1100, minHeight: 720)
                .background(WindowFrameKeeper(autosaveName: "Mac2HogMainWindow"))
        }
        .commands { AppCommands(state: state, playback: state.playback) }

        Settings {
            SettingsView()
                .environmentObject(state)
                .environmentObject(state.playback)
                .environmentObject(state.activity)
                .environmentObject(state.oscLog)
        }
    }
}

/// First launch: open the main window filling the screen (not full-screen). Afterwards AppKit
/// remembers the size and position the user left it at under `autosaveName`.
struct WindowFrameKeeper: NSViewRepresentable {
    let autosaveName: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            let name = NSWindow.FrameAutosaveName(autosaveName)
            if !window.setFrameUsingName(name), let screen = window.screen ?? NSScreen.main {
                window.setFrame(screen.visibleFrame, display: true)
            }
            window.setFrameAutosaveName(name)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
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
