#if os(macOS)
import SwiftUI
import Mac2HogCore

struct AppCommands: Commands {
    @ObservedObject var state: AppState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Single-Song Show") { state.newProject() }.keyboardShortcut("n")
            Button("New Setlist") { state.newSetlist() }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Open Show or Setlist…") { state.openProjectPanel() }.keyboardShortcut("o")
            Divider()
            Button(state.setlist == nil ? "Import Song…" : "Add Songs to Setlist…") { state.importSongPanel() }.keyboardShortcut("i")
            Button("Import Hog Showfile…") { state.importShowfilePanel() }.keyboardShortcut("i", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save Show") { state.saveProject() }.keyboardShortcut("s")
            Button("Save Show As…") { state.saveProjectAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Show Autosave Folder") { state.showAutosaveFolder() }
            Divider()
            Button("Export Cue Sheet (CSV)…") { state.exportCueSheet() }
            Button("Export LTC Timecode (WAV)…") { state.exportLTC(includeSong: false) }
            Button("Export Song + LTC (stereo WAV)…") { state.exportLTC(includeSong: true) }
        }
        CommandMenu("Show") {
            Button(state.isPlaying ? "Pause" : "Play") { state.togglePlay() }
                .keyboardShortcut(.return, modifiers: [.command])
            Button("Stop") { state.stop() }.keyboardShortcut(".", modifiers: [.command])
            if state.setlist != nil {
                Button("Start Setlist From the Top") { state.startSetlist(from: -1) }
            }
            Divider()
            Button("GO Next Cue") { state.goNextCue() }.keyboardShortcut("g", modifiers: [.command])
            Button("Back One Cue") { state.backCue() }.keyboardShortcut("b", modifiers: [.command])
            Divider()
            Picker("Mode", selection: $state.mode) {
                ForEach(PlaybackMode.allCases) { Text($0.title).tag($0) }
            }
            Divider()
            Button("Add Trigger at Playhead") { state.addTrigger(at: state.currentTime) }.keyboardShortcut("t", modifiers: [.command])
            Button("Analyze Song") { state.analyze() }.keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(state.project.songPath == nil)
        }
    }
}
#endif
