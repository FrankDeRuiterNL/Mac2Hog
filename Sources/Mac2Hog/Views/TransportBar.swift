#if os(macOS)
import SwiftUI
import AppKit
import Mac2HogCore

struct TransportBar: View {
    @EnvironmentObject var state: AppState
    @Binding var showGenerator: Bool
    @State private var bpmText = ""

    var body: some View {
        HStack(spacing: 14) {
            // Transport
            HStack(spacing: 6) {
                Button { state.stop() } label: { Image(systemName: "stop.fill") }.help("Stop (Esc)")
                Button { state.skip(-5) } label: { Image(systemName: "gobackward.5") }
                Button { state.togglePlay() } label: {
                    Image(systemName: state.isPlaying ? "pause.fill" : "play.fill").frame(width: 22)
                }
                .help(state.mode == .timecode ? "Play / pause (Space)" : "Play / pause (⌘↩)")
                Button { state.skip(5) } label: { Image(systemName: "goforward.5") }
            }
            .controlSize(.large)
            .disabled(state.project.songPath == nil)

            // Clock
            VStack(alignment: .leading, spacing: 0) {
                Text(state.currentTimecode.description)
                    .font(.system(size: 26, weight: .semibold, design: .monospaced))
                    .foregroundStyle(state.isPlaying ? Color.green : Color.primary)
                Text("\(formatTime(state.currentTime)) / \(formatTime(state.duration))  ·  \(state.project.timecodeRate.rawValue) fps\(barBeat)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 230, alignment: .leading)

            // Tempo
            if let a = state.project.analysis {
                HStack(spacing: 4) {
                    TextField("BPM", text: $bpmText, onCommit: { if let v = Double(bpmText) { state.applyTempo(v) } })
                        .frame(width: 56)
                        .multilineTextAlignment(.trailing)
                        .onAppear { bpmText = String(format: "%.1f", a.bpm) }
                        .onChange(of: a.bpm) { bpmText = String(format: "%.1f", $0) }
                    Menu("BPM") {
                        Section("Detected candidates") {
                            ForEach(a.tempoCandidates, id: \.bpm) { c in
                                Button(String(format: "%.1f BPM (%.0f%%)", c.bpm, c.confidence * 100)) { state.applyTempo(c.bpm) }
                            }
                        }
                        Button("Double tempo (×2)") { state.applyTempo(a.bpm * 2) }
                        Button("Half tempo (÷2)") { state.applyTempo(a.bpm / 2) }
                        Divider()
                        Button("Move bar start one beat earlier") { state.shiftDownbeat(by: -1) }
                        Button("Move bar start one beat later") { state.shiftDownbeat(by: 1) }
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 52)
                }
                .help("Suggested main tempo. Edit to lock a constant beat grid.")
            }

            Divider().frame(height: 30)

            Picker("Mode", selection: $state.mode) {
                Text("Timecode").tag(PlaybackMode.timecode)
                Text("Manual").tag(PlaybackMode.manual)
            }
            .pickerStyle(.segmented)
            .frame(width: 170)
            .help("Timecode: cues fire automatically while the song plays. Manual: press Space to fire the next cue.")

            if state.mode == .manual {
                Button { state.goNextCue() } label: {
                    Text("GO").font(.headline).frame(width: 46)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.large)
                .help("Fire next cue (Space)")
                VStack(alignment: .leading, spacing: 0) {
                    Text("Next: \(state.cueStack.next?.name ?? "— end —")").font(.callout.bold()).lineLimit(1)
                    Text("Current: \(state.cueStack.current?.name ?? "—")").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: 200, alignment: .leading)
            } else if let next = nextTrigger {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Next: \(next.name)").font(.callout.bold()).lineLimit(1)
                    Text(String(format: "in %.1f s", next.time - state.currentTime)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .frame(maxWidth: 200, alignment: .leading)
            }

            Spacer()

            if state.isAnalyzing {
                VStack(alignment: .trailing, spacing: 2) {
                    ProgressView(value: state.analysisProgress).frame(width: 140)
                    Text(state.analysisStatus).font(.caption2).foregroundStyle(.secondary)
                }
            }

            Button { showGenerator = true } label: { Label("Generate Cues", systemImage: "wand.and.stars") }
                .disabled(state.project.analysis == nil)

            HStack(spacing: 5) {
                Circle().fill(state.networkOK ? Color.green : Color.red).frame(width: 9, height: 9)
                Text(state.settings.consoleHost).font(.caption.monospacedDigit())
            }
            .help(state.networkStatus)

            if #available(macOS 14.0, *) {
                SettingsLink { Image(systemName: "gearshape") }
            } else {
                Button { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) } label: { Image(systemName: "gearshape") }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var nextTrigger: ShowTrigger? {
        state.project.sortedTriggers.first { $0.enabled && $0.time > state.currentTime }
    }

    private var barBeat: String {
        guard let beats = state.project.analysis?.beats,
              let b = beats.last(where: { $0.time <= state.currentTime + 0.01 }) else { return "" }
        return "  ·  bar \(b.bar).\(b.beatInBar)"
    }
}

func formatTime(_ t: Double) -> String {
    let t = max(0, t)
    return String(format: "%d:%05.2f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
}
#endif
