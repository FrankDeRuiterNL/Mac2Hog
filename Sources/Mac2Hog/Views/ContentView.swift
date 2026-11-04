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
            if state.project.songPath == nil {
                EmptyStateView()
            } else {
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
                    .frame(minWidth: 520, idealWidth: 700)
                    InspectorView()
                        .frame(minWidth: 360, idealWidth: 420, maxWidth: 600)
                }
                Divider()
                OSCLogView()
                    .frame(minHeight: 90, idealHeight: 130, maxHeight: 200)
            }
        }
        .sheet(isPresented: $showGenerator) { GenerateTriggersSheet() }
        .alert("Mac2Hog", isPresented: Binding(get: { state.alertMessage != nil }, set: { if !$0 { state.alertMessage = nil } })) {
            Button("OK") { state.alertMessage = nil }
        } message: {
            Text(state.alertMessage ?? "")
        }
        .navigationTitle(state.project.name + (state.isDirty ? " — Edited" : ""))
    }
}

struct EmptyStateView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform.and.magnifyingglass")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("Build a Hog 4 light show from a song")
                .font(.title2.bold())
            Text("Import a .wav or .mp3. Mac2Hog finds the tempo, beat grid, snare hits, breaks and song sections, generates timecode, and lets you attach Hog cuelists, scenes and macros that fire over OSC.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520)
            HStack(spacing: 12) {
                Button { state.importSongPanel() } label: { Label("Import Song…", systemImage: "music.note") }
                    .controlSize(.large).buttonStyle(.borderedProminent)
                Button { state.openProjectPanel() } label: { Label("Open Show…", systemImage: "folder") }
                    .controlSize(.large)
                Button { state.importShowfilePanel() } label: { Label("Import Showfile…", systemImage: "square.and.arrow.down") }
                    .controlSize(.large)
            }
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
