#if os(macOS)
import SwiftUI
import AppKit
import Mac2HogCore

struct InspectorView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var activity: CueActivity

    var body: some View {
        // The selected cue, or with Follow on the last fired / running cue.
        if let id = activity.focusedCueID ?? state.selectedTriggerID, let binding = state.binding(for: id) {
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

/// Label column used by every grid in the inspector so all sections line up.
struct InspectorLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .frame(minWidth: 72, alignment: .trailing)
            .gridColumnAlignment(.trailing)
    }
}

struct TriggerEditor: View {
    @EnvironmentObject var state: AppState
    @Binding var trigger: ShowTrigger
    @State private var timecodeText = ""

    var body: some View {
        Form {
            Section {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        InspectorLabel("Name")
                        TextField("", text: $trigger.name, prompt: Text("Cue name"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        InspectorLabel("Start")
                        HStack(spacing: 6) {
                            Picker("Start", selection: $trigger.startMode) {
                                ForEach(CueStartMode.allCases) { Text($0.displayName).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                            if trigger.startMode != .timecode {
                                Text("+")
                                SecondsField(value: $trigger.delay, width: 56)
                                Text("s")
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    if trigger.startMode != .timecode {
                        GridRow {
                            Color.clear.frame(width: 1, height: 1)
                            Text(startExplanation).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    GridRow {
                        InspectorLabel("Duration")
                        HStack(spacing: 6) {
                            SecondsField(value: $trigger.duration, width: 56)
                            Text("s")
                            Spacer(minLength: 0)
                        }
                        .help("How long this cue runs (e.g. its fade time). A following Wait cue or command starts after it.")
                    }
                    GridRow {
                        InspectorLabel("Timecode")
                        HStack(spacing: 6) {
                            TextField("", text: $timecodeText, prompt: Text("hh:mm:ss:ff"))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .font(.body.monospacedDigit())
                                .frame(width: 118)
                                .onSubmit(commitTimecode)
                                .disabled(trigger.startMode != .timecode)
                            Text(String(format: "%.3f s", trigger.time))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                .fixedSize()
                            Spacer(minLength: 4)
                            if trigger.startMode == .timecode {
                                Button { nudge(-1) } label: { Image(systemName: "chevron.left") }.help("One beat earlier")
                                Button { nudge(1) } label: { Image(systemName: "chevron.right") }.help("One beat later")
                                if state.editingState == nil {
                                    Button("Playhead") { trigger.time = state.currentTime }.help("Move this cue to the playhead")
                                }
                            }
                        }
                        .controlSize(.small)
                    }
                    GridRow {
                        InspectorLabel("Enabled")
                        HStack {
                            Toggle("", isOn: $trigger.enabled).labelsHidden().toggleStyle(.switch).controlSize(.small)
                            Spacer()
                            Text(trigger.source.displayName).font(.caption).foregroundStyle(.secondary)
                                .help("Where this cue came from")
                        }
                    }
                    GridRow {
                        InspectorLabel("Notes")
                        TextField("", text: $trigger.notes, prompt: Text("Notes"), axis: .vertical)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1...3)
                    }
                }
                .padding(.vertical, 2)
            } header: {
                HStack {
                    Text("Cue")
                    Spacer()
                    Button { state.deleteTriggers([trigger.id]) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.primary)   // white in dark mode
                    .help("Delete this cue")
                }
            }

            Section {
                if trigger.commands.isEmpty {
                    Text("No commands yet — this cue won't change anything on the console.").foregroundStyle(.secondary)
                }
                ForEach($trigger.commands) { $command in
                    CommandEditor(
                        command: $command, show: state.project.show, mapper: state.mapper,
                        onDelete: {
                            let id = command.id
                            // Defer so the ForEach binding isn't mutated while it is being rendered.
                            DispatchQueue.main.async { trigger.commands.removeAll { $0.id == id } }
                        },
                        onAddRelease: command.canAddRelease && command.timing == nil ? {
                            let source = command
                            DispatchQueue.main.async {
                                let i = trigger.commands.firstIndex { $0.id == source.id } ?? trigger.commands.count - 1
                                trigger.commands.insert(source.releaseCommand(), at: i + 1)
                            }
                        } : nil,
                        isPredefined: state.isPredefined(command),
                        onTogglePredefined: { state.togglePredefined(command) })
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
        }
        .formStyle(.grouped)
        .onAppear { timecodeText = state.project.timecode(at: trigger.time).description }
        .onChange(of: trigger.time) { t in timecodeText = state.project.timecode(at: t).description }
    }

    private var startExplanation: String {
        let d = SecondsText.format(trigger.delay)
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
    /// Shown as a blue ↩︎ button for a Go of a cuelist / scene: adds the matching Release below.
    var onAddRelease: (() -> Void)? = nil
    /// nil hides the star; otherwise filled yellow when the command is a predefined trigger.
    var isPredefined: Bool? = nil
    var onTogglePredefined: (() -> Void)? = nil

    private var actions: [HogAction] {
        HogAction.allCases
    }

    // Labels sit in a fixed left column and controls fill the rest. Every control hides its own
    // label, otherwise a grouped Form puts the title on the left and pushes the control to the far right.
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    label("Action")
                    HStack(spacing: 8) {
                        Picker("Action", selection: $command.action) {
                            ForEach(actions) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        if command.action.usesObject {
                            Picker("Type", selection: $command.objectKind) {
                                ForEach(HogObjectKind.allCases) { Text($0.displayName).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                        Spacer(minLength: 0)
                        if let onAddRelease {
                            Button(action: onAddRelease) { Image(systemName: "arrow.uturn.backward.circle.fill") }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.blue)
                                .help("Add a Release of this \(command.objectKind.displayName.lowercased()) below, with Follow / Wait timing")
                        }
                        if let isPredefined, let onTogglePredefined {
                            Button(action: onTogglePredefined) { Image(systemName: isPredefined ? "star.fill" : "star") }
                                .buttonStyle(.borderless)
                                .foregroundStyle(isPredefined ? Color.yellow : Color.secondary)
                                .help(isPredefined ? "This command is a predefined trigger (click to remove it from Predefined)"
                                                   : "Save this command as a predefined trigger")
                        }
                        Button(role: .destructive, action: onDelete) { Image(systemName: "minus.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                            .help("Remove this command")
                    }
                }
                if command.action.usesObject {
                    GridRow {
                        label(command.objectKind.displayName)
                        objectRow
                    }
                    if command.action == .gotoCue {
                        GridRow {
                            label("Cue")
                            cueRow
                        }
                    }
                }
                if command.action.usesMaster {
                    GridRow {
                        label("Master")
                        HStack {
                            numberField("Master", value: $command.master)
                            Stepper("", value: $command.master, in: 0...200).labelsHidden()
                            Spacer(minLength: 0)
                        }
                    }
                    if command.action == .masterFader {
                        GridRow {
                            label("Level")
                            HStack {
                                Slider(value: $command.level, in: 0...100).labelsHidden()
                                Text("\(Int(command.level))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                            }
                        }
                    }
                }
                if command.timing != nil {
                    GridRow {
                        label("Timing")
                        HStack(spacing: 6) {
                            Picker("Timing", selection: Binding(get: { command.timing?.mode ?? .follow },
                                                                set: { command.timing?.mode = $0 })) {
                                Text("Follow").tag(CueStartMode.follow)
                                Text("Wait").tag(CueStartMode.wait)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                            Text("+")
                            SecondsField(value: Binding(get: { command.timing?.seconds ?? 0 },
                                                        set: { command.timing?.seconds = $0 }), width: 56)
                            Text("s")
                            Spacer(minLength: 0)
                        }
                    }
                    GridRow {
                        Color.clear.frame(width: 1, height: 1)
                        Text(command.timing?.mode == .wait
                             ? "Sent \(SecondsText.format(command.timing?.seconds ?? 0)) s after this cue has finished (fire + Duration)."
                             : "Sent \(SecondsText.format(command.timing?.seconds ?? 0)) s after this cue fires.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if command.action == .custom {
                    GridRow {
                        label("Address")
                        TextField("", text: $command.customAddress, prompt: Text("/hog/hardware/maingo"))
                            .labelsHidden()
                            .font(.body.monospaced())
                    }
                    GridRow {
                        label("Arguments")
                        TextField("", text: $command.customArguments, prompt: Text("e.g. 1 0.5 \"text\""))
                            .labelsHidden()
                            .font(.body.monospaced())
                    }
                }
            }

            if command.action.usesObject && !HogAction.actions(for: command.objectKind).contains(command.action) {
                Text("\(command.objectKind.displayName)s don't support \(command.action.displayName).")
                    .font(.caption).foregroundStyle(.orange)
            }

            Text(mapper.messages(for: command).map(\.description).joined(separator: "\n").ifEmpty("(invalid OSC address)"))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }

    private func label(_ text: String) -> some View { InspectorLabel(text) }

    private func numberField(_ prompt: String, value: Binding<Int>) -> some View {
        TextField("", value: value, format: .number.grouping(.never), prompt: Text(prompt))
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 56)
    }

    /// Showfile picker (name + number), then the number itself with an up/down stepper.
    @ViewBuilder
    private var objectRow: some View {
        let objects = show?.objects(of: command.objectKind) ?? []
        HStack(spacing: 8) {
            if !objects.isEmpty {
                Picker(command.objectKind.displayName, selection: Binding(
                    get: { command.objectNumber },
                    set: { setObject($0, objects: objects) })) {
                    ForEach(objects) { Text("\($0.number)  \($0.name)").tag($0.number) }
                    if !objects.contains(where: { $0.number == command.objectNumber }) {
                        Text("\(command.objectNumber) (not in Hog XML)").tag(command.objectNumber)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            numberStepper(prompt: "No.", help: "\(command.objectKind.displayName) number",
                          text: Binding(get: { command.objectNumber }, set: { setObject($0, objects: objects) }),
                          existing: objects.map(\.number))
            Spacer(minLength: 0)
        }
    }

    /// Cue picker from the imported cuelist, then the cue number with an up/down stepper.
    @ViewBuilder
    private var cueRow: some View {
        let cues = show?.object(kind: command.objectKind, number: command.objectNumber)?.cues ?? []
        HStack(spacing: 8) {
            if !cues.isEmpty {
                Picker("Cue", selection: $command.cueNumber) {
                    ForEach(cues) { Text("\($0.number)  \($0.name)").tag($0.number) }
                    if !cues.contains(where: { $0.number == command.cueNumber }) { Text(command.cueNumber).tag(command.cueNumber) }
                }
                .labelsHidden()
                .fixedSize()
            }
            numberStepper(prompt: "Cue", help: "Cue number", text: $command.cueNumber, existing: cues.map(\.number))
            Spacer(minLength: 0)
        }
    }

    private func setObject(_ number: String, objects: [HogObject]) {
        command.objectNumber = number
        command.label = objects.first { $0.number == number }?.name ?? ""
    }

    /// Editable number with ▲▼. With a showfile the arrows step through the numbers that exist there.
    private func numberStepper(prompt: String, help: String, text: Binding<String>, existing: [String]) -> some View {
        HStack(spacing: 2) {
            TextField("", text: text, prompt: Text(prompt))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 56)
            Stepper("", onIncrement: { text.wrappedValue = HogNumber.step(text.wrappedValue, by: 1, existing: existing) },
                    onDecrement: { text.wrappedValue = HogNumber.step(text.wrappedValue, by: -1, existing: existing) })
                .labelsHidden()
        }
        .help(existing.isEmpty ? help : "\(help) — arrows step through the Hog XML")
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
#endif
