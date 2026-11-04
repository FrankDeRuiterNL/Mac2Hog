#if os(macOS)
import SwiftUI
import AppKit
import Mac2HogCore

struct SettingsView: View {
    var body: some View {
        TabView {
            NetworkSettings().tabItem { Label("Network", systemImage: "network") }
            OSCSettings().tabItem { Label("OSC", systemImage: "dot.radiowaves.left.and.right") }
            TimecodeSettings().tabItem { Label("Timecode", systemImage: "clock") }
            SongSettings().tabItem { Label("Song", systemImage: "music.note") }
            ShowfileSettings().tabItem { Label("Showfile", systemImage: "doc.richtext") }
            PredefinedSettings().tabItem { Label("Predefined", systemImage: "star") }
        }
        .frame(width: 720, height: 560)
    }
}

private struct PortField: View {
    let title: String
    @Binding var port: UInt16
    var body: some View {
        TextField(title, value: Binding(get: { Int(port) }, set: { port = UInt16(clamping: max(1, $0)) }),
                  format: .number.grouping(.never))
    }
}

struct NetworkSettings: View {
    @EnvironmentObject var state: AppState
    @State private var host = ""

    var body: some View {
        Form {
            Section {
                TextField("Console IP address / hostname", text: $host, onCommit: { state.settings.consoleHost = host.trimmingCharacters(in: .whitespaces) })
                    .onAppear { host = state.settings.consoleHost }
                PortField(title: "Console OSC input port", port: $state.settings.consolePort)
                HStack {
                    Circle().fill(state.networkOK ? Color.green : Color.red).frame(width: 9, height: 9)
                    Text(state.networkStatus).font(.caption)
                    Spacer()
                    Button("Apply") { state.settings.consoleHost = host.trimmingCharacters(in: .whitespaces); state.configureNetwork() }
                    Button("Send test message") { state.settings.consoleHost = host.trimmingCharacters(in: .whitespaces); state.sendTestMessage() }
                }
            } header: {
                Text("Hog 4 console")
            } footer: {
                Text("On the Hog: Setup → Control Panel → Network → enable OSC Input and use the same port. The Mac and the console (or Hog 4 PC) must be on the same network. UDP is connectionless, so a test message can only be confirmed on the console (or with feedback below).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Listen for Hog OSC output (status feedback)", isOn: $state.settings.feedbackEnabled)
                PortField(title: "Feedback port on this Mac", port: $state.settings.feedbackPort)
                    .disabled(!state.settings.feedbackEnabled)
            } header: {
                Text("Feedback")
            } footer: {
                Text("Set the Hog's OSC Output to this Mac's IP and port to see incoming messages in the OSC log.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct OSCSettings: View {
    @EnvironmentObject var state: AppState
    @State private var testList = "1"
    @State private var testCue = "2"

    var body: some View {
        Form {
            Section("Message format") {
                TextField("Address prefix", text: $state.settings.osc.addressPrefix)
                Picker("Number arguments", selection: $state.settings.osc.numberFormat) {
                    ForEach(OSCNumberFormat.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Goto cue format", selection: $state.settings.osc.gotoStyle) {
                    ForEach(GotoStyle.allCases) { Text($0.displayName).tag($0) }
                }
                Toggle("Send key release (0) after key press (1)", isOn: $state.settings.osc.sendKeyRelease)
            }
            Section {
                HStack {
                    Text("Cuelist")
                    TextField("", text: $testList).frame(width: 60)
                    Text("Cue")
                    TextField("", text: $testCue).frame(width: 60)
                }
                ForEach(GotoStyle.allCases) { style in
                    let msg = state.mapper.gotoMessage(list: testList, cue: testCue, style: style)
                    HStack {
                        Image(systemName: style == state.settings.osc.gotoStyle ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(style == state.settings.osc.gotoStyle ? Color.green : Color.secondary)
                        Text(msg.description).font(.caption.monospaced()).textSelection(.enabled)
                        Spacer()
                        Button("Send") { state.engine.send(raw: msg) }
                        Button("Use") { state.settings.osc.gotoStyle = style }
                            .disabled(style == state.settings.osc.gotoStyle)
                    }
                }
            } header: {
                Text("Goto cue test")
            } footer: {
                Text("Send each variant and watch the cuelist on the Hog; click Use on the one that jumps to the right cue. Tip: enable feedback (Settings › Network) and press a cue on the console to see in the OSC log exactly how the Hog itself formats it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Timing") {
                HStack {
                    Text("Latency compensation")
                    Slider(value: $state.settings.latencyCompensationMs, in: 0...200, step: 5)
                    Text("\(Int(state.settings.latencyCompensationMs)) ms").monospacedDigit().frame(width: 60)
                }
                Toggle("Release used cuelists/scenes when the show is stopped", isOn: $state.settings.sendReleaseOnStop)
            }
            Section("Hog 4 OSC reference") {
                VStack(alignment: .leading, spacing: 3) {
                    ref("Go cuelist", "/hog/playback/go/0  <list>")
                    ref("Goto cue", "/hog/playback/go/0  \"<list>.<cue>\"  (see Goto cue format)")
                    ref("Halt / resume / release", "/hog/playback/halt|resume|release/0  <list>")
                    ref("Scene go / halt / release", "/hog/playback/go|halt|release/1  <scene>")
                    ref("Macro go", "/hog/playback/go/2  <macro>")
                    ref("Master go / pause / back", "/hog/hardware/go|pause|goback/<master>  1|0")
                    ref("Fader", "/hog/hardware/fader/<master>  0-255")
                    ref("Main go / halt / back", "/hog/hardware/maingo|mainhalt|mainback  1|0")
                }
                .font(.caption)
            }
        }
        .formStyle(.grouped)
    }

    private func ref(_ title: String, _ address: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).frame(width: 170, alignment: .leading)
            Text(address).font(.caption.monospaced()).textSelection(.enabled)
        }
    }
}

struct TimecodeSettings: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section("Song timecode") {
                Picker("Frame rate", selection: $state.settings.timecodeRate) {
                    ForEach(TimecodeRate.allCases) { Text($0.displayName).tag($0) }
                }
                Stepper("Song starts at \(String(format: "%02d", state.settings.timecodeStartHour)):00:00:00",
                        value: $state.settings.timecodeStartHour, in: 0...23)
                Text("Song length: \(state.project.timecodeStart.description) → \(state.project.timecode(at: state.duration).description)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Play LTC on the right audio channel (song on the left)", isOn: $state.settings.ltcOnRightChannel)
                HStack {
                    Button("Export LTC WAV…") { state.exportLTC(includeSong: false) }
                    Button("Export song + LTC WAV…") { state.exportLTC(includeSong: true) }
                }
                .disabled(state.project.songPath == nil)
            } header: {
                Text("Linear timecode output")
            } footer: {
                Text("Mac2Hog fires the cues itself over OSC from its internal timecode clock. The LTC options are for when you also want the Hog 4 (via its LTC input) to chase the same timecode, for example to run timecode-triggered cuelists on the console.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct SongSettings: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section("Current song") {
                HStack {
                    Text(state.project.songPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "None").bold()
                    Spacer()
                    Button("Import Song…") { state.importSongPanel() }
                    Button("Re-analyze") { state.analyze() }.disabled(state.project.songPath == nil || state.isAnalyzing)
                }
                if state.isAnalyzing { ProgressView(value: state.analysisProgress) { Text(state.analysisStatus).font(.caption) } }
                else if !state.analysisStatus.isEmpty { Text(state.analysisStatus).font(.caption).foregroundStyle(.secondary) }
            }
            Section("Recent songs") {
                if state.settings.recentSongs.isEmpty { Text("No songs imported yet").foregroundStyle(.secondary) }
                ForEach(state.settings.recentSongs, id: \.self) { path in
                    HStack {
                        Image(systemName: path == state.project.songPath ? "checkmark.circle.fill" : "music.note")
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                        Spacer()
                        if !FileManager.default.fileExists(atPath: path) { Text("missing").foregroundStyle(.red).font(.caption) }
                        Button("Select") { state.importSong(URL(fileURLWithPath: path)) }
                            .disabled(path == state.project.songPath || !FileManager.default.fileExists(atPath: path))
                    }
                }
            }
            Section {
                HStack {
                    Text("Tempo range")
                    TextField("", value: $state.settings.minBPM, format: .number).frame(width: 50)
                    Text("–")
                    TextField("", value: $state.settings.maxBPM, format: .number).frame(width: 50)
                    Text("BPM")
                }
                HStack {
                    Text("Snare sensitivity")
                    Slider(value: Binding(get: { 1 - state.settings.snareSensitivity }, set: { state.settings.snareSensitivity = 1 - $0 }), in: 0...1)
                    Text(state.settings.snareSensitivity < 0.35 ? "more hits" : (state.settings.snareSensitivity > 0.65 ? "fewer hits" : "balanced"))
                        .font(.caption).frame(width: 70)
                }
                Stepper("Minimum song part length: \(state.settings.minSectionBars) bars", value: $state.settings.minSectionBars, in: 2...16)
            } header: {
                Text("Analysis")
            } footer: {
                Text("Changes apply the next time you analyze. Narrow the tempo range if the detected tempo is half or double the real tempo.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Reusable named triggers: a name plus the OSC command(s) sent to the Hog.
/// They appear under "+ Add" in the cue inspector and as "Add predefined" in the cue list.
struct PredefinedSettings: View {
    @EnvironmentObject var state: AppState
    @State private var selection: UUID?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(state.settings.predefinedTriggers) { p in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name.isEmpty ? "Untitled" : p.name).bold()
                            Text(p.commands.isEmpty ? "No command" : p.commands.map(\.summary).joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .tag(p.id)
                    }
                    .onMove { state.settings.predefinedTriggers.move(fromOffsets: $0, toOffset: $1) }
                }
                Divider()
                HStack {
                    Button { add() } label: { Image(systemName: "plus") }.help("New predefined trigger")
                    Button { remove() } label: { Image(systemName: "minus") }.disabled(selection == nil)
                    Button { duplicate() } label: { Image(systemName: "plus.square.on.square") }
                        .disabled(selection == nil).help("Duplicate")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(minWidth: 220, idealWidth: 240)

            Group {
                if let id = selection, state.settings.predefinedTriggers.contains(where: { $0.id == id }) {
                    PredefinedEditor(predefined: Binding(
                        get: { state.settings.predefinedTriggers.first { $0.id == id } ?? PredefinedTrigger(id: id, name: "") },
                        set: { new in
                            if let i = state.settings.predefinedTriggers.firstIndex(where: { $0.id == id }) {
                                state.settings.predefinedTriggers[i] = new
                            }
                        }))
                    .id(id)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "star").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Predefined triggers are reusable commands, e.g. “Blackout”, “Strobe hit” or “Smoke burst”.")
                            .multilineTextAlignment(.center)
                        Text("Create one with +, give it a name and choose the OSC command(s) to send. Add it to any cue with + Add in the cue inspector.")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("New Predefined Trigger") { add() }.padding(.top, 6)
                    }
                    .padding(30)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 380)
        }
    }

    private func add() {
        let p = PredefinedTrigger(name: "New trigger \(state.settings.predefinedTriggers.count + 1)",
                                  commands: [.go(.cuelist, state.project.show?.objects(of: .cuelist).first?.number ?? "1")])
        state.settings.predefinedTriggers.append(p)
        selection = p.id
    }

    private func remove() {
        guard let id = selection else { return }
        state.settings.predefinedTriggers.removeAll { $0.id == id }
        selection = state.settings.predefinedTriggers.first?.id
    }

    private func duplicate() {
        guard let id = selection, let p = state.settings.predefinedTriggers.first(where: { $0.id == id }) else { return }
        let copy = PredefinedTrigger(name: p.name + " copy", commands: p.commands.map { $0.withNewID() })
        state.settings.predefinedTriggers.append(copy)
        selection = copy.id
    }
}

struct PredefinedEditor: View {
    @EnvironmentObject var state: AppState
    @Binding var predefined: PredefinedTrigger

    var body: some View {
        Form {
            Section("Name") {
                TextField("Name", text: $predefined.name)
            }
            Section {
                if predefined.commands.isEmpty {
                    Text("Add the OSC command this trigger sends to the Hog.").foregroundStyle(.secondary)
                }
                ForEach($predefined.commands) { $command in
                    CommandEditor(command: $command, show: state.project.show, mapper: state.mapper) {
                        let id = command.id
                        DispatchQueue.main.async { predefined.commands.removeAll { $0.id == id } }
                    }
                }
            } header: {
                HStack {
                    Text("OSC commands")
                    Spacer()
                    Menu {
                        Button("Go Cuelist") { predefined.commands.append(.go(.cuelist, "1")) }
                        Button("Goto Cue in Cuelist") { predefined.commands.append(HogCommand(action: .gotoCue)) }
                        Button("Go Scene") { predefined.commands.append(.go(.scene, "1")) }
                        Button("Go Macro") { predefined.commands.append(.go(.macro, "1")) }
                        Button("Release Cuelist") { predefined.commands.append(HogCommand(action: .release)) }
                        Divider()
                        Button("Master Go") { predefined.commands.append(HogCommand(action: .masterGo)) }
                        Button("Master Fader Level") { predefined.commands.append(HogCommand(action: .masterFader)) }
                        Button("Main Go") { predefined.commands.append(HogCommand(action: .mainGo)) }
                        Divider()
                        Button("Custom OSC") { predefined.commands.append(HogCommand(action: .custom)) }
                    } label: { Label("Add", systemImage: "plus") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            Section {
                Button { state.engine.send(commands: predefined.commands) } label: { Label("Send now (test)", systemImage: "bolt.fill") }
                    .disabled(predefined.commands.isEmpty)
            }
        }
        .formStyle(.grouped)
    }
}

struct ShowfileSettings: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section {
                HStack {
                    if let show = state.project.show {
                        VStack(alignment: .leading) {
                            Text(show.name).bold()
                            Text("\(show.objects(of: .cuelist).count) cuelists · \(show.objects(of: .scene).count) scenes · \(show.objects(of: .macro).count) macros")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("No showfile loaded").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Import…") { state.importShowfilePanel() }
                    if state.project.show != nil {
                        Button("Unload") { state.project.show = nil; state.settings.selectedShowfile = nil }
                    }
                }
            } header: {
                Text("Current showfile")
            } footer: {
                Text("Supported: Hog 4 XML exports (in Hog 4 OS open the Cuelist, Scene or Macro directory, select the items and choose Export), CSV lists (type,number,name[,cue,cue name]) and saved Mac2Hog libraries. Native .shw files are binary databases that can only be opened by Hog OS — export them to XML first.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Recent showfiles") {
                if state.settings.recentShowfiles.isEmpty { Text("None").foregroundStyle(.secondary) }
                ForEach(state.settings.recentShowfiles, id: \.self) { path in
                    HStack {
                        Image(systemName: path == state.settings.selectedShowfile ? "checkmark.circle.fill" : "doc")
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                        Spacer()
                        Button("Select") { state.loadShowfile(URL(fileURLWithPath: path)) }
                            .disabled(!FileManager.default.fileExists(atPath: path))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
#endif
