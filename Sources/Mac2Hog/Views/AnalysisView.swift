#if os(macOS)
import SwiftUI
import AppKit
import Mac2HogCore

/// Lists everything the analyzer found, each with a button to turn it into a trigger.
struct AnalysisView: View {
    @EnvironmentObject var state: AppState
    @State private var snareFilter = 0

    var body: some View {
        if let a = state.project.analysis {
            List {
                Section("Tempo") {
                    HStack {
                        Text(String(format: "%.1f BPM", a.bpm)).font(.title3.bold())
                        Text("· \(a.beatsPerBar)/4 · \(a.downbeats.count) bars · \(formatTime(a.duration))").foregroundStyle(.secondary)
                        Spacer()
                        ForEach(a.tempoCandidates.dropFirst(), id: \.bpm) { c in
                            Button(String(format: "%.0f?", c.bpm)) { state.applyTempo(c.bpm) }
                                .help(String(format: "Alternative tempo, confidence %.0f%%", c.confidence * 100))
                        }
                    }
                    Text("Timecode \(state.project.timecodeStart.description) → \(state.project.timecode(at: a.duration).description) at \(state.project.timecodeRate.displayName)")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Song parts (\(a.sections.count))") {
                    ForEach(a.sections) { s in
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 3).fill(sectionColor(s.kind)).frame(width: 12, height: 12)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.name).bold()
                                Text("\(state.project.timecode(at: s.start).description) – \(state.project.timecode(at: s.end).description) · \(formatTime(s.duration)) · group \(s.group)")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            ProgressView(value: s.energy).frame(width: 60).help("Relative energy")
                            Button("Start") { state.addTrigger(at: s.start, name: s.name, source: .sectionStart) }
                            Button("End") { state.addTrigger(at: s.end, name: "End \(s.name)", source: .sectionEnd) }
                            Button { state.seek(to: s.start) } label: { Image(systemName: "play.circle") }.buttonStyle(.borderless)
                        }
                        .controlSize(.small)
                    }
                }

                Section("Breaks (\(a.breaks.count))") {
                    if a.breaks.isEmpty { Text("No breaks detected").foregroundStyle(.secondary) }
                    ForEach(Array(a.breaks.enumerated()), id: \.offset) { i, b in
                        HStack {
                            Text("Break \(i + 1)").bold()
                            Text("\(state.project.timecode(at: b.start).description) – \(state.project.timecode(at: b.end).description) (\(formatTime(b.duration)))")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Spacer()
                            Button("Start") { state.addTrigger(at: b.start, name: "Break \(i + 1) start", source: .breakStart) }
                            Button("End") { state.addTrigger(at: b.end, name: "Break \(i + 1) end", source: .breakEnd) }
                            Button { state.seek(to: b.start) } label: { Image(systemName: "play.circle") }.buttonStyle(.borderless)
                        }
                        .controlSize(.small)
                    }
                }

                Section {
                    ForEach(Array(filteredSnares(a).enumerated()), id: \.offset) { i, h in
                        HStack {
                            Image(systemName: "diamond.fill").foregroundStyle(h.onGrid ? Color.orange : Color.orange.opacity(0.4))
                            Text(state.project.timecode(at: h.time).description).font(.body.monospacedDigit())
                            Text(barBeat(a, h.time)).font(.caption).foregroundStyle(.secondary)
                            ProgressView(value: h.strength).frame(width: 50)
                            Spacer()
                            Button("Add trigger") { state.addTrigger(at: h.time, name: "Snare \(barBeat(a, h.time))", source: .snare) }
                            Button { state.seek(to: max(0, h.time - 1)) } label: { Image(systemName: "play.circle") }.buttonStyle(.borderless)
                        }
                        .controlSize(.small)
                    }
                } header: {
                    HStack {
                        Text("Snare hits (\(a.snares.count))")
                        Spacer()
                        Picker("", selection: $snareFilter) {
                            Text("All").tag(0); Text("On grid").tag(1); Text("Strong").tag(2)
                        }
                        .pickerStyle(.segmented).frame(width: 200).labelsHidden()
                    }
                }
            }
        } else {
            VStack(spacing: 12) {
                if state.isAnalyzing {
                    ProgressView(value: state.analysisProgress) { Text(state.analysisStatus) }.frame(width: 260)
                } else {
                    Text("The song has not been analysed yet.").foregroundStyle(.secondary)
                    Button("Analyze Song") { state.analyze() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func filteredSnares(_ a: AnalysisResult) -> [Hit] {
        switch snareFilter {
        case 1: return a.snares.filter(\.onGrid)
        case 2: return a.snares.filter { $0.strength >= 0.5 }
        default: return a.snares
        }
    }

    private func barBeat(_ a: AnalysisResult, _ t: Double) -> String {
        guard let b = a.beats.min(by: { abs($0.time - t) < abs($1.time - t) }) else { return "" }
        return "bar \(b.bar).\(b.beatInBar)"
    }
}

/// Browser for cuelists, scenes and macros from the imported Hog show.
struct ShowObjectsView: View {
    @EnvironmentObject var state: AppState
    @State private var kind: HogObjectKind = .cuelist
    @State private var newNumber = ""
    @State private var newName = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if let show = state.project.show {
                    Label(show.name, systemImage: "doc.richtext").bold()
                    Text("\(show.objects(of: .cuelist).count) cuelists · \(show.objects(of: .scene).count) scenes · \(show.objects(of: .macro).count) macros")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("No showfile imported").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Import Showfile…") { state.importShowfilePanel() }
            }
            .padding(8)
            Picker("", selection: $kind) {
                ForEach(HogObjectKind.allCases) { Text($0.displayName + "s").tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 8)

            List {
                ForEach(state.project.show?.objects(of: kind) ?? []) { obj in
                    HStack {
                        Text(obj.number).font(.body.monospacedDigit()).frame(width: 44, alignment: .trailing)
                        Text(obj.name.isEmpty ? "(unnamed)" : obj.name)
                        if !obj.cues.isEmpty { Text("\(obj.cues.count) cues").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Go now") { state.engine.send(commands: [.go(obj.kind, obj.number, label: obj.name)]) }
                        Button("Attach to cue") { attach(obj) }
                            .disabled(state.selectedTriggerID == nil)
                            .help("Add a Go command for this object to the selected trigger")
                    }
                    .controlSize(.small)
                }
            }

            Divider()
            HStack {
                Text("Add manually:").font(.caption)
                TextField("No.", text: $newNumber).frame(width: 50)
                TextField("Name", text: $newName)
                Button("Add \(kind.displayName)") {
                    guard !newNumber.isEmpty else { return }
                    var show = state.project.show ?? HogShow(name: "Manual")
                    show.objects.removeAll { $0.kind == kind && $0.number == newNumber }
                    show.objects.append(HogObject(kind: kind, number: newNumber, name: newName))
                    state.project.show = show
                    newNumber = ""; newName = ""
                }
            }
            .controlSize(.small)
            .padding(8)
        }
    }

    private func attach(_ obj: HogObject) {
        guard let id = state.selectedTriggerID, let b = state.binding(for: id) else { return }
        b.wrappedValue.commands.append(.go(obj.kind, obj.number, label: obj.name))
    }
}
#endif
