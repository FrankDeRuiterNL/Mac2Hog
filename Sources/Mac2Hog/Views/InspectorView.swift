#if os(macOS)
import SwiftUI
import AppKit
import Mac2HogCore

struct InspectorView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if let id = state.selectedTriggerID, let binding = state.binding(for: id) {
            TriggerEditor(trigger: binding)
                .id(id)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3").font(.largeTitle).foregroundStyle(.secondary)
                Text("Select a cue to attach Hog commands").foregroundStyle(.secondary)
                Text("Tip: double-click the waveform to add a cue, or use Generate Cues to create cues from the song parts, breaks and snare hits.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 280)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct TriggerEditor: View {
    @EnvironmentObject var state: AppState
    @Binding var trigger: ShowTrigger
    @State private var timecodeText = ""

    var body: some View {
        Form {
            Section("Cue") {
                TextField("Name", text: $trigger.name)
                Picker("Start", selection: $trigger.startMode) {
                    ForEach(CueStartMode.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                if trigger.startMode != .timecode {
                    HStack {
                        Text(trigger.startMode == .follow ? "Follow previous cue's start +" : "Wait for previous cue's end +")
                        TextField("", value: $trigger.delay, format: .number)
                            .frame(width: 60)
                            .multilineTextAlignment(.trailing)
                        Text("s")
                    }
                    Text(startExplanation).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Duration")
                    TextField("", value: $trigger.duration, format: .number)
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                    Text("s")
                    Spacer()
                    Text("how long this cue runs (fade time); a next Wait cue starts after it")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack {
                    TextField("Timecode", text: $timecodeText, onCommit: commitTimecode)
                        .font(.body.monospacedDigit())
                        .frame(width: 120)
                        .disabled(trigger.startMode != .timecode)
                    Text(String(format: "%.3f s", trigger.time)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    if trigger.startMode == .timecode {
                        Button { nudge(-1) } label: { Image(systemName: "chevron.left") }.help("One beat earlier")
                        Button { nudge(1) } label: { Image(systemName: "chevron.right") }.help("One beat later")
                        if state.editingState == nil {
                            Button("Playhead") { trigger.time = state.currentTime }.help("Move this cue to the playhead")
                        }
                    }
                }
                .controlSize(.small)
                HStack {
                    Toggle("Enabled", isOn: $trigger.enabled)
                    Spacer()
                    Text(trigger.source.displayName).foregroundStyle(.secondary)
                }
                TextField("Notes", text: $trigger.notes, axis: .vertical).lineLimit(1...3)
            }

            Section {
                if trigger.commands.isEmpty {
                    Text("No commands yet — this cue won't change anything on the console.").foregroundStyle(.secondary)
                }
                ForEach($trigger.commands) { $command in
                    CommandEditor(command: $command, show: state.project.show, mapper: state.mapper) {
                        let id = command.id
                        // Defer so the ForEach binding isn't mutated while it is being rendered.
                        DispatchQueue.main.async { trigger.commands.removeAll { $0.id == id } }
                    }
                }
            } header: {
                HStack {
                    Text("Hog commands")
                    Spacer()
                    Menu {
                        if !state.settings.predefinedTriggers.isEmpty {
                            Section("Predefined") {
                                ForEach(state.settings.predefinedTriggers) { p in
                                    Button("★ \(p.name)") { trigger.commands.append(contentsOf: p.instantiate()) }
                                }
                            }
                            Divider()
                        }
                        Button("Go Cuelist") { add(.go(.cuelist, firstNumber(.cuelist))) }
                        Button("Goto Cue in Cuelist") { add(HogCommand(action: .gotoCue, objectNumber: firstNumber(.cuelist))) }
                        Button("Go Scene") { add(.go(.scene, firstNumber(.scene))) }
                        Button("Go Macro") { add(.go(.macro, firstNumber(.macro))) }
                        Button("Release Cuelist") { add(HogCommand(action: .release, objectNumber: firstNumber(.cuelist))) }
                        Divider()
                        Button("Master Go") { add(HogCommand(action: .masterGo)) }
                        Button("Master Fader Level") { add(HogCommand(action: .masterFader)) }
                        Button("Main Go") { add(HogCommand(action: .mainGo)) }
                        Divider()
                        Button("Custom OSC") { add(HogCommand(action: .custom)) }
                        Divider()
                        if #available(macOS 14.0, *) {
                            SettingsLink { Text("Manage Predefined Triggers…") }
                        } else {
                            Button("Manage Predefined Triggers…") { openSettings() }
                        }
                    } label: { Label("Add", systemImage: "plus") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }

            Section {
                HStack {
                    Button { state.fire(trigger) } label: { Label("Fire now", systemImage: "bolt.fill") }
                    Button { state.seek(to: max(0, trigger.time - 2)) } label: { Label("Preview", systemImage: "play") }
                        .help("Jump 2 seconds before this cue")
                    Spacer()
                    if !trigger.commands.isEmpty {
                        Button("Copy to all \(trigger.source.displayName) cues") { state.applyCommandsToAll(from: trigger.id) }
                    }
                }
                .controlSize(.small)
                if !trigger.commands.isEmpty {
                    Button { state.saveAsPredefined(trigger) } label: { Label("Save commands as predefined trigger", systemImage: "star") }
                        .controlSize(.small)
                }
                Button("Delete cue", role: .destructive) { state.deleteTriggers([trigger.id]) }
                    .controlSize(.small)
            }
        }
        .formStyle(.grouped)
        .onAppear { timecodeText = state.project.timecode(at: trigger.time).description }
        .onChange(of: trigger.time) { t in timecodeText = state.project.timecode(at: t).description }
    }

    private var startExplanation: String {
        let d = trigger.delay == trigger.delay.rounded() ? String(Int(trigger.delay)) : String(format: "%.1f", trigger.delay)
        switch trigger.startMode {
        case .follow: return "Fires \(d) s after the previous cue fired."
        case .wait: return "Fires \(d) s after the previous cue has finished (its start + its duration)."
        case .timecode: return ""
        }
    }

    private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    private func add(_ c: HogCommand) {
        var c = c
        if c.action.usesObject, let obj = state.project.show?.object(kind: c.objectKind, number: c.objectNumber) { c.label = obj.name }
        trigger.commands.append(c)
    }

    private func firstNumber(_ kind: HogObjectKind) -> String {
        state.project.show?.objects(of: kind).first?.number ?? "1"
    }

    private func commitTimecode() {
        if let tc = Timecode(string: timecodeText, rate: state.project.timecodeRate) {
            trigger.time = max(0, state.project.songTime(for: tc))
        } else if let seconds = Double(timecodeText) {
            trigger.time = max(0, seconds)
        }
        timecodeText = state.project.timecode(at: trigger.time).description
    }

    private func nudge(_ beats: Double) {
        let bpm = state.project.analysis?.bpm ?? 120
        trigger.time = max(0, trigger.time + beats * 60 / bpm)
    }
}

struct CommandEditor: View {
    @Binding var command: HogCommand
    let show: HogShow?
    let mapper: HogOSCMapper
    let onDelete: () -> Void

    private var actions: [HogAction] {
        HogAction.allCases
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Action", selection: $command.action) {
                    ForEach(actions) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 190)
                if command.action.usesObject {
                    Picker("Type", selection: $command.objectKind) {
                        ForEach(HogObjectKind.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 100)
                }
                Spacer()
                Button(role: .destructive, action: onDelete) { Image(systemName: "minus.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
            }

            if command.action.usesObject {
                objectRow
                if command.action == .gotoCue { cueRow }
                if !HogAction.actions(for: command.objectKind).contains(command.action) {
                    Text("\(command.objectKind.displayName)s don't support \(command.action.displayName).")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            if command.action.usesMaster {
                Stepper("Master \(command.master)", value: $command.master, in: 0...200)
                if command.action == .masterFader {
                    HStack {
                        Slider(value: $command.level, in: 0...100)
                        Text("\(Int(command.level))%").monospacedDigit().frame(width: 40)
                    }
                }
            }
            if command.action == .custom {
                TextField("OSC address", text: $command.customAddress).font(.body.monospaced())
                TextField("Arguments (e.g. 1 0.5 \"text\")", text: $command.customArguments).font(.body.monospaced())
            }

            Text(mapper.messages(for: command).map(\.description).joined(separator: "\n").ifEmpty("(invalid OSC address)"))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var objectRow: some View {
        let objects = show?.objects(of: command.objectKind) ?? []
        HStack {
            if !objects.isEmpty {
                Picker(command.objectKind.displayName, selection: Binding(
                    get: { command.objectNumber },
                    set: { n in
                        command.objectNumber = n
                        command.label = objects.first { $0.number == n }?.name ?? ""
                    })) {
                    ForEach(objects) { Text("\($0.number)  \($0.name)").tag($0.number) }
                    if !objects.contains(where: { $0.number == command.objectNumber }) {
                        Text("\(command.objectNumber) (not in showfile)").tag(command.objectNumber)
                    }
                }
            }
            TextField("No.", text: Binding(get: { command.objectNumber }, set: { n in
                command.objectNumber = n
                command.label = show?.object(kind: command.objectKind, number: n)?.name ?? ""
            }))
            .frame(width: objects.isEmpty ? 80 : 50)
        }
    }

    @ViewBuilder
    private var cueRow: some View {
        let cues = show?.object(kind: command.objectKind, number: command.objectNumber)?.cues ?? []
        HStack {
            if !cues.isEmpty {
                Picker("Cue", selection: $command.cueNumber) {
                    ForEach(cues) { Text("\($0.number)  \($0.name)").tag($0.number) }
                    if !cues.contains(where: { $0.number == command.cueNumber }) { Text(command.cueNumber).tag(command.cueNumber) }
                }
            }
            TextField("Cue", text: $command.cueNumber).frame(width: cues.isEmpty ? 80 : 50)
        }
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
#endif
