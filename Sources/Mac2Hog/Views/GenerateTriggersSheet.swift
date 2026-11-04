#if os(macOS)
import SwiftUI
import AppKit
import Mac2HogCore

struct GenerateTriggersSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var generator = TriggerGenerator()
    @State private var attachSnareCommand = false
    @State private var snareCommand = HogCommand.go(.cuelist, "1")

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Generate cues from the song analysis").font(.title3.bold()).padding()
            Form {
                Section("Song structure") {
                    Toggle("A cue at the start of every song part (intro, verse, chorus …)", isOn: $generator.sectionStarts)
                    Toggle("A cue at the end of every song part", isOn: $generator.sectionEnds)
                    Toggle("Cues at the start and end of every break", isOn: $generator.breaks)
                    Stepper(generator.everyNBars == 0 ? "No bar cues" : "A cue every \(generator.everyNBars) bars",
                            value: $generator.everyNBars, in: 0...64, step: 1)
                }
                Section("Snare hits") {
                    Picker("Snare cues", selection: $generator.snares) {
                        ForEach(TriggerGenerator.SnareMode.allCases) { Text($0.displayName).tag($0) }
                    }
                    if generator.snares != .none, let a = state.project.analysis {
                        Text("Limit to song parts (none selected = whole song):").font(.caption)
                        ScrollView {
                            VStack(alignment: .leading) {
                                ForEach(a.sections) { s in
                                    Toggle(s.name, isOn: Binding(get: { generator.snareSectionIDs.contains(s.id) },
                                                                 set: { on in
                                                                     if on { generator.snareSectionIDs.insert(s.id) } else { generator.snareSectionIDs.remove(s.id) }
                                                                 }))
                                }
                            }
                        }
                        .frame(maxHeight: 110)
                        Toggle("Attach this command to every snare cue", isOn: $attachSnareCommand)
                        if attachSnareCommand {
                            CommandEditor(command: $snareCommand, show: state.project.show, mapper: state.mapper) { attachSnareCommand = false }
                        }
                    }
                }
                if let a = state.project.analysis {
                    Text("Preview: \(preview(a)) cues will be generated.").foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add to existing cues") { run(replace: false) }
                Button("Replace all cues") { run(replace: true) }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 560, height: 620)
    }

    private func configured() -> TriggerGenerator {
        var g = generator
        g.snareCommand = attachSnareCommand ? snareCommand : nil
        return g
    }

    private func preview(_ a: AnalysisResult) -> Int { configured().generate(from: a).count }

    private func run(replace: Bool) {
        state.generateTriggers(configured(), replace: replace)
        dismiss()
    }
}

struct OSCLogView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("OSC output").font(.caption.bold())
                Text(state.networkStatus).font(.caption).foregroundStyle(state.networkOK ? Color.secondary : Color.red)
                Spacer()
                Button("Send test") { state.sendTestMessage() }
                Button("Clear") { state.log.removeAll() }
            }
            .controlSize(.small)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            ScrollViewReader { proxy in
                List(state.log) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(entry.date, format: .dateTime.hour().minute().second())
                            .foregroundStyle(.secondary)
                        Text(entry.title).bold().foregroundStyle(entry.incoming ? Color.blue : Color.primary)
                        Text(entry.detail).foregroundStyle(entry.isError ? Color.red : Color.secondary)
                            .textSelection(.enabled)
                    }
                    .font(.caption.monospaced())
                    .id(entry.id)
                }
                .listStyle(.plain)
                .onChange(of: state.log.count) { _ in
                    if let last = state.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }
}
#endif
