#if os(macOS)
import SwiftUI
import AppKit
import Mac2HogCore

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var showGenerator = false
    @State private var leftTab = 0

    var body: some View {
        VStack(spacing: 0) {
            TransportBar(showGenerator: $showGenerator)
            Divider()
            if state.setlist != nil {
                HSplitView {
                    SetlistSidebar()
                        .frame(minWidth: 230, idealWidth: 270, maxWidth: 380)
                    setlistEditor
                        .frame(minWidth: 700)
                }
            } else if state.project.songPath == nil {
                EmptyStateView()
            } else {
                songEditor
            }
        }
        .sheet(isPresented: $showGenerator) { GenerateTriggersSheet() }
        .alert("Mac2Hog", isPresented: Binding(get: { state.alertMessage != nil }, set: { if !$0 { state.alertMessage = nil } })) {
            Button("OK") { state.alertMessage = nil }
        } message: {
            Text(state.alertMessage ?? "")
        }
        .navigationTitle((state.setlist.map { "\($0.name) — \(state.project.name)" } ?? state.project.name) + (state.isDirty ? " — Edited" : ""))
    }

    @ViewBuilder
    private var setlistEditor: some View {
        if let st = state.editingState {
            StateEditorView(stateKind: st)
        } else if state.project.songPath != nil {
            songEditor
        } else {
            VStack(spacing: 14) {
                Image(systemName: "music.note.list").font(.system(size: 48)).foregroundStyle(.secondary)
                Text("Add songs to the setlist").font(.title3.bold())
                Button { state.addSongsToSetlistPanel() } label: { Label("Add Songs…", systemImage: "plus") }
                    .controlSize(.large).buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var songEditor: some View {
        VStack(spacing: 0) {
            WaveformTimeline()
                .frame(height: 250)
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    Picker("", selection: $leftTab) {
                        Text("Cue List").tag(0)
                        Text("Song Analysis").tag(1)
                        Text("Show Objects").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(8)
                    switch leftTab {
                    case 0: CueListView()
                    case 1: AnalysisView()
                    default: ShowObjectsView()
                    }
                }
                .frame(minWidth: 480, idealWidth: 700)
                InspectorView()
                    .frame(minWidth: 360, idealWidth: 420, maxWidth: 600)
            }
            Divider()
            OSCLogView()
                .frame(minHeight: 90, idealHeight: 130, maxHeight: 200)
        }
    }
}

/// Editor for the Starting / Waiting / Ending light state of a setlist.
struct StateEditorView: View {
    @EnvironmentObject var state: AppState
    let stateKind: SetlistState

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(stateKind.displayName).font(.title2.bold())
                    Text(stateKind.explanation + " The first cue fires at its time (seconds from the start of the state); use Follow / Wait to chain the next cues.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(String(format: "Length: %.1f s", CueTiming.length(of: state.project.triggers)) + lengthNote)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { state.engine.runSequence(state.project.triggers) } label: { Label("Test run", systemImage: "play") }
                    .help("Fire this state's cues now, with their timing")
                Button { state.engine.cancelScheduled() } label: { Label("Cancel", systemImage: "xmark") }
            }
            .padding(12)
            Divider()
            HSplitView {
                CueListView()
                    .frame(minWidth: 420, idealWidth: 600)
                InspectorView()
                    .frame(minWidth: 360, idealWidth: 420, maxWidth: 600)
            }
            Divider()
            OSCLogView()
                .frame(minHeight: 90, idealHeight: 130, maxHeight: 200)
        }
    }

    private var lengthNote: String {
        guard let set = state.setlist else { return "" }
        switch stateKind {
        case .starting: return String(format: " · first song starts %.0f s after the setlist starts", set.startDelay)
        case .waiting: return String(format: " · pause between songs is %.0f s by default", set.defaultGap)
        case .ending: return ""
        }
    }
}

struct EmptyStateView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform.and.magnifyingglass")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("Build a Hog light show from a song")
                .font(.title2.bold())
            Text("Import a .wav or .mp3. Mac2Hog finds the tempo, beat grid, snare hits, breaks and song sections, generates timecode, and lets you attach Hog cuelists, scenes and macros that fire over OSC.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520)
            HStack(spacing: 16) {
                SessionChoice(icon: "music.note", title: "Single Song",
                              text: "One song with its own timecode and cue list.") { state.importSongPanel() }
                SessionChoice(icon: "music.note.list", title: "Setlist",
                              text: "Several songs that follow each other, with Starting, Waiting and Ending light states.") {
                    state.newSetlist()
                    state.addSongsToSetlistPanel()
                }
            }
            HStack(spacing: 12) {
                Button { state.openProjectPanel() } label: { Label("Open Show or Setlist…", systemImage: "folder") }
                Button { state.importShowfilePanel() } label: { Label("Import Showfile…", systemImage: "square.and.arrow.down") }
            }
            .controlSize(.large)
            if !state.settings.recentSongs.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent songs").font(.headline)
                    ForEach(state.settings.recentSongs.prefix(6), id: \.self) { path in
                        Button(URL(fileURLWithPath: path).lastPathComponent) { state.importSong(URL(fileURLWithPath: path)) }
                            .buttonStyle(.link)
                    }
                }
                .padding(.top, 8)
            }
            if let show = state.project.show {
                Label("Showfile loaded: \(show.name) (\(show.objects.count) objects)", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif

#if os(macOS)
struct SessionChoice: View {
    let icon: String
    let title: String
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 34))
                Text(title).font(.headline)
                Text(text).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(width: 220, height: 140)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 2))
    }
}
#endif
