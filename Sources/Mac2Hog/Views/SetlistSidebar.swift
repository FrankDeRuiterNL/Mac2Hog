#if os(macOS)
import SwiftUI
import AppKit
import Mac2HogCore

/// Setlist overview: Starting state, the songs (drag to reorder) with the pause after each, Waiting and Ending states.
struct SetlistSidebar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if let set = state.setlist {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Setlist name", text: Binding(get: { set.name }, set: { v in state.updateSetlist { $0.name = v } }))
                        .font(.headline)
                        .textFieldStyle(.plain)
                    Text("\(set.songs.count) songs · \(formatTime(set.totalDuration)) total")
                        .font(.caption).foregroundStyle(.secondary)
                    if let saved = state.lastAutosave {
                        Label {
                            Text("Auto-saved \(saved, format: .dateTime.hour().minute().second())" +
                                 (state.projectURL == nil ? " (Autosave folder — use Save As to choose a file)" : ""))
                        } icon: { Image(systemName: "checkmark.icloud") }
                        .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(10)

                List(selection: Binding(get: { state.selection }, set: { if let s = $0 { state.select(s) } })) {
                    Section("Before") {
                        stateRow(.starting, set: set)
                    }
                    Section("Songs") {
                        ForEach(Array(set.songs.enumerated()), id: \.element.id) { index, song in
                            songRow(index: index, song: song, set: set)
                                .tag(SetlistSelection.song(song.id))
                                .contextMenu {
                                    Button("Start Setlist From Here") { state.startSetlist(from: index == 0 ? 0 : index) }
                                    Button("Remove From Setlist", role: .destructive) { state.removeSongs([song.id]) }
                                }
                        }
                        .onMove { state.moveSongs(from: $0, to: $1) }
                    }
                    Section("Between & after") {
                        stateRow(.waiting, set: set)
                        stateRow(.ending, set: set)
                    }
                }
                .disabled(state.phase.isRunning)

                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Button { state.addSongsToSetlistPanel() } label: { Label("Add Songs…", systemImage: "plus") }
                        Spacer()
                        if case .song(let id)? = state.selection {
                            Button { state.removeSongs([id]) } label: { Image(systemName: "minus") }
                                .help("Remove the selected song")
                        }
                    }
                    secondsField("Default pause between songs", value: set.defaultGap) { v in state.updateSetlist { $0.defaultGap = v } }
                    secondsField("First song starts after", value: set.startDelay) { v in state.updateSetlist { $0.startDelay = v } }
                    Toggle("Start next song automatically", isOn: Binding(get: { set.autoAdvance },
                                                                         set: { v in state.updateSetlist { $0.autoAdvance = v } }))
                }
                .controlSize(.small)
                .padding(10)
                .disabled(state.phase.isRunning)
            }
        }
    }

    private func stateRow(_ kind: SetlistState, set: Setlist) -> some View {
        let cues = set.cues(for: kind)
        return HStack {
            Image(systemName: kind == .starting ? "sunrise" : (kind == .waiting ? "hourglass" : "sunset"))
                .foregroundStyle(isActive(kind) ? Color.orange : Color.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.displayName).bold()
                Text(cues.isEmpty ? "No cues" : "\(cues.count) cue\(cues.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .tag(SetlistSelection.state(kind))
    }

    private func songRow(index: Int, song: SetlistSong, set: Setlist) -> some View {
        let playing = state.phase == .song(index: index)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("\(index + 1)").font(.body.monospacedDigit()).foregroundStyle(.secondary).frame(width: 20, alignment: .trailing)
                if playing { Image(systemName: "speaker.wave.2.fill").foregroundStyle(.green) }
                Text(song.name).bold().lineLimit(1)
                Spacer()
                if let a = song.project.analysis {
                    Text(formatTime(a.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.mini).help("Analysing…")
                }
            }
            HStack(spacing: 6) {
                Text(song.project.analysis.map { String(format: "%.0f BPM", $0.bpm) } ?? "")
                Text("\(song.project.triggers.count) cues")
                Spacer()
                if index < set.songs.count - 1 {
                    Image(systemName: "pause.circle")
                    TextField("", value: Binding(get: { song.gapAfter ?? set.defaultGap },
                                                 set: { v in state.updateSetlist { s in
                                                     if let i = s.songs.firstIndex(where: { $0.id == song.id }) {
                                                         s.songs[i].gapAfter = v == s.defaultGap ? nil : max(0, v)
                                                     }
                                                 } }),
                              format: .number)
                        .frame(width: 40)
                        .multilineTextAlignment(.trailing)
                        .help("Pause after this song (seconds)")
                    Text("s")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func isActive(_ kind: SetlistState) -> Bool {
        switch (kind, state.phase) {
        case (.starting, .starting), (.waiting, .waiting), (.ending, .ending): return true
        default: return false
        }
    }

    private func secondsField(_ title: String, value: Double, set: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("", value: Binding(get: { value }, set: { set(max(0, $0)) }), format: .number)
                .frame(width: 50)
                .multilineTextAlignment(.trailing)
            Text("s")
        }
    }
}
#endif
