#if os(macOS)
import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import Mac2HogCore

enum PlaybackMode: String, CaseIterable, Identifiable {
    case timecode, manual
    var id: String { rawValue }
    var title: String { self == .timecode ? "Timecode (automatic)" : "Manual cue stack (space = GO)" }
    var short: String { self == .timecode ? "Timecode" : "Manual" }
}

/// What is shown in the editor when a setlist is open.
enum SetlistSelection: Hashable {
    case song(UUID)
    case state(SetlistState)
}

/// Where a running setlist currently is.
enum SetlistPhase: Equatable {
    case idle
    case starting(until: Date)
    case song(index: Int)
    case waiting(afterIndex: Int, until: Date?)
    case ending
    case finished

    var isRunning: Bool {
        switch self {
        case .idle, .finished: return false
        default: return true
        }
    }
}

struct OSCLogEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let songTime: Double
    let title: String
    let detail: String
    let isError: Bool
    let incoming: Bool
}

@MainActor
final class AppState: ObservableObject {
    // MARK: Persistent settings
    @Published var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            saveSettings()
            if settings.consoleHost != oldValue.consoleHost || settings.consolePort != oldValue.consolePort
                || settings.osc != oldValue.osc || settings.latencyCompensationMs != oldValue.latencyCompensationMs {
                configureNetwork()
            }
            if settings.feedbackEnabled != oldValue.feedbackEnabled || settings.feedbackPort != oldValue.feedbackPort {
                configureFeedback()
            }
            if settings.ltcOnRightChannel != oldValue.ltcOnRightChannel { reloadPlayer() }
            if editingState == nil,
               settings.timecodeRate != oldValue.timecodeRate || settings.timecodeStartHour != oldValue.timecodeStartHour {
                project.timecodeRate = settings.timecodeRate
                project.timecodeStart = Timecode(hours: settings.timecodeStartHour, rate: settings.timecodeRate)
            }
        }
    }

    // MARK: Show document
    @Published var project = ShowProject() {
        didSet {
            // @Published re-enters didSet when the property is written from inside it, so guard against recursion.
            guard !isUpdatingProject else { return }
            isUpdatingProject = true
            defer { isUpdatingProject = false }
            // Keep the cue list ordered and Follow / Wait times up to date after every edit.
            var normalized = project.triggers
            CueTiming.normalize(&normalized)
            if normalized != project.triggers { project.triggers = normalized }
            engine.setTriggers(project.triggers)
            cueStack = CueStack(triggers: project.triggers, keeping: cueStack)
            isDirty = true
            writeBackToSetlist()
        }
    }
    private var isUpdatingProject = false
    @Published var projectURL: URL?
    @Published var isDirty = false {
        didSet { if isDirty { scheduleAutosave() } }
    }
    /// When the last auto-save happened (shown in the setlist sidebar).
    @Published private(set) var lastAutosave: Date?
    private var autosaveWork: DispatchWorkItem?
    private var autosaveName = UUID().uuidString

    // MARK: Setlist
    /// nil = single-song show. Otherwise `project` is the song or state currently being edited.
    @Published var setlist: Setlist?
    @Published private(set) var selection: SetlistSelection?
    @Published private(set) var phase: SetlistPhase = .idle
    /// Fast-changing playback values live in their own object so the 30 Hz updates only redraw the
    /// views that show them (transport, playhead), not the whole window.
    let playback = PlaybackClock()
    var clock: Date { playback.now }
    private var phaseWork: DispatchWorkItem?
    /// Last imported showfile, shared by every song and state of a setlist.
    private var currentShow: HogShow?

    var editingState: SetlistState? {
        if case .state(let st)? = selection { return st }
        return nil
    }

    var currentSongIndex: Int? {
        guard case .song(let id)? = selection else { return nil }
        return setlist?.songs.firstIndex { $0.id == id }
    }

    // MARK: Playback
    @Published var mode: PlaybackMode = .timecode {
        didSet { engine.setAutoFire(mode == .timecode); if mode == .manual { cueStack.reset() } }
    }
    var currentTime: Double { playback.currentTime }
    var isPlaying: Bool { playback.isPlaying }
    /// Follow the playhead / fired cues in the waveform and the cue list.
    @Published var followPlayhead = true
    /// Last fired / running cue and inspector focus (separate observable, see CueActivity).
    let activity = CueActivity()
    var runningCueIDs: Set<UUID> { activity.runningCueIDs }
    private var runningTokens: [UUID: UUID] = [:]
    @Published private(set) var duration: Double = 0
    @Published var cueStack = CueStack(triggers: [])
    var lastFiredID: UUID? { activity.lastFiredID }

    // MARK: Analysis
    @Published private(set) var isAnalyzing = false
    @Published private(set) var analysisProgress: Double = 0
    @Published private(set) var analysisStatus = ""
    private var decodedAudio: MonoAudio?

    // MARK: UI
    @Published var selectedTriggerID: UUID? {
        didSet { if activity.focusedCueID != selectedTriggerID { activity.focusedCueID = selectedTriggerID } }
    }
    let oscLog = OSCLogStore()
    @Published var networkStatus = "Not configured"
    @Published var networkOK = false
    @Published var alertMessage: String?
    @Published var zoom: Double = 40 // pixels per second
    @Published var snapToBeat = true

    let engine = ShowEngine()
    private let keyMonitor = KeyMonitor()
    private var feedback: OSCListener?
    private var uiTimer: Timer?
    private static let settingsKey = "Mac2Hog.settings"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let s = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = s
        } else {
            settings = AppSettings()
        }
        project = ShowProject(timecodeRate: settings.timecodeRate,
                              timecodeStart: Timecode(hours: settings.timecodeStartHour, rate: settings.timecodeRate))
        isDirty = false
        engine.onFire = { [weak self] event in self?.handle(event) }
        engine.onSongFinished = { [weak self] in self?.songFinished() }
        configureNetwork()
        configureFeedback()
        if let path = settings.selectedShowfile, FileManager.default.fileExists(atPath: path) {
            loadShowfile(URL(fileURLWithPath: path), remember: false)
        }
        keyMonitor.start(onSpace: { [weak self] in self?.spacePressed() },
                         onEscape: { [weak self] in self?.stop() })
        // Common run-loop modes: keep the playhead moving while lists scroll or menus are open.
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshTransport() }
        }
        RunLoop.main.add(timer, forMode: .common)
        uiTimer = timer
    }

    // MARK: - Settings & network

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: Self.settingsKey) }
    }

    var mapper: HogOSCMapper { HogOSCMapper(configuration: settings.osc) }

    func configureNetwork() {
        do {
            try engine.configure(host: settings.consoleHost, port: settings.consolePort, mapper: mapper,
                                 latency: settings.latencyCompensationMs / 1000)
            networkStatus = "Sending to \(settings.consoleHost):\(settings.consolePort)"
            networkOK = true
        } catch {
            networkStatus = error.localizedDescription
            networkOK = false
        }
    }

    func configureFeedback() {
        feedback?.stop()
        feedback = nil
        guard settings.feedbackEnabled else { return }
        let listener = OSCListener(port: settings.feedbackPort)
        do {
            try listener.start { [weak self] message in
                Task { @MainActor in
                    self?.appendLog(OSCLogEntry(songTime: self?.currentTime ?? 0, title: "← \(message.address)",
                                                detail: message.description, isError: false, incoming: true))
                }
            }
            feedback = listener
        } catch {
            alertMessage = "Could not listen for Hog feedback on port \(settings.feedbackPort): \(error.localizedDescription)"
        }
    }

    func sendTestMessage() {
        engine.send(commands: [HogCommand(action: .custom, customAddress: "\(settings.osc.addressPrefix)/hardware/period",
                                          customArguments: "0", label: "Connection test")])
    }

    // MARK: - Logging

    private func handle(_ event: ShowEngine.FireEvent) {
        if let t = event.trigger, project.triggers.contains(where: { $0.id == t.id }) {
            if activity.lastFiredID != t.id { activity.lastFiredID = t.id }
            markRunning(t)
            // Follow: the inspector shows the cue that just fired (without touching the list selection).
            if followPlayhead, activity.focusedCueID != t.id { activity.focusedCueID = t.id }
        }
        let title = event.trigger.map { "\(project.timecode(at: event.songTime))  \($0.name)" } ?? "OSC"
        let detail = event.messages.isEmpty ? "(no commands)" : event.messages.map(\.description).joined(separator: "   ")
        appendLog(OSCLogEntry(songTime: event.songTime, title: title, detail: event.error.map { "\(detail)  ⚠︎ \($0)" } ?? detail,
                              isError: event.error != nil, incoming: false))
        // Only publish real changes: every AppState change redraws the whole window.
        if let error = event.error {
            if networkOK { networkOK = false }
            if networkStatus != error { networkStatus = error }
        } else if !event.messages.isEmpty, !networkOK {
            networkOK = true
            configureNetwork()
        }
    }

    /// A fired cue with a duration counts as running until its duration has elapsed.
    private func markRunning(_ trigger: ShowTrigger) {
        let duration = project.triggers.first { $0.id == trigger.id }?.duration ?? trigger.duration
        guard duration > 0 else { return }
        let token = UUID()
        runningTokens[trigger.id] = token
        activity.runningCueIDs.insert(trigger.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.runningTokens[trigger.id] == token else { return }
            self.runningTokens[trigger.id] = nil
            self.activity.runningCueIDs.remove(trigger.id)
        }
    }

    private func appendLog(_ entry: OSCLogEntry) { oscLog.append(entry) }

    // MARK: - Transport

    private func refreshTransport() {
        let t = engine.currentTime
        if abs(t - playback.currentTime) > 0.001 { playback.currentTime = t }
        let playing = engine.isPlaying
        if playing != playback.isPlaying { playback.isPlaying = playing }
        if phase.isRunning { playback.now = Date() }
    }

    var currentTimecode: Timecode { project.timecode(at: currentTime) }

    /// The big Play button / Space in timecode mode.
    func togglePlay() {
        if setlist != nil {
            switch phase {
            case .idle, .finished:
                startSetlist(from: currentSongIndex.map { $0 } ?? -1)
                return
            case .waiting(let i, _):
                startSong(at: i + 1)   // skip the rest of the pause
                return
            case .starting:
                startSong(at: 0)
                return
            case .ending:
                return
            case .song:
                break
            }
        }
        isPlaying ? pause() : play()
    }

    func play() {
        guard engine.hasAudio else { alertMessage = "Import a song first."; return }
        engine.play()
        refreshTransport()
    }

    func pause() { engine.pause(); refreshTransport() }

    func stop() {
        phaseWork?.cancel()
        phaseWork = nil
        phase = .idle
        engine.stop()
        if !activity.runningCueIDs.isEmpty { activity.runningCueIDs = [] }
        runningTokens = [:]
        if settings.sendReleaseOnStop {
            var seen = Set<String>()
            let all = project.triggers + (setlist.map { $0.songs.flatMap(\.project.triggers) + $0.startingState + $0.waitingState + $0.endingState } ?? [])
            let releases = all.flatMap(\.commands).filter(\.action.usesObject).compactMap { c -> HogCommand? in
                guard seen.insert("\(c.objectKind.rawValue):\(c.objectNumber)").inserted else { return nil }
                return HogCommand(action: .release, objectKind: c.objectKind, objectNumber: c.objectNumber)
            }
            if !releases.isEmpty { engine.send(commands: releases) }
        }
        cueStack.reset()
        refreshTransport()
    }

    func seek(to time: Double) { engine.seek(to: time); refreshTransport() }

    func skip(_ seconds: Double) { seek(to: currentTime + seconds) }

    private func spacePressed() {
        switch mode {
        case .manual: goNextCue()
        case .timecode: togglePlay()
        }
    }

    // MARK: - Manual cue stack

    func goNextCue() {
        let chain = cueStack.goChain()
        guard let cue = chain.first?.trigger else { NSSound.beep(); return }
        engine.fire(cue)
        if chain.count > 1 { engine.schedule(Array(chain.dropFirst())) }
        // Follow along in the song so the waveform shows where we are.
        if !isPlaying && engine.hasAudio { seek(to: cue.time) }
    }

    func backCue() {
        if let cue = cueStack.back() { engine.fire(cue) }
    }

    func setNextCue(_ id: UUID) { cueStack.select(id: id) }

    func fire(_ trigger: ShowTrigger) { engine.fire(trigger) }

    // MARK: - Song import & analysis

    func importSongPanel() {
        if setlist != nil { addSongsToSetlistPanel(); return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mp3, .wav, .aiff, .mpeg4Audio, .audio]
        panel.message = "Choose a song (.wav or .mp3)"
        if panel.runModal() == .OK, let url = panel.url { importSong(url) }
    }

    func importSong(_ url: URL, analyze: Bool = true) {
        project.songPath = url.path
        if project.name == "Untitled" { project.name = url.deletingPathExtension().lastPathComponent }
        settings.remember(song: url.path)
        decodedAudio = nil
        reloadPlayer()
        if analyze { self.analyze() }
    }

    /// Points the current song at a different audio file (e.g. after moving files) without re-analysing.
    /// In a setlist this updates the song's path in the .mac2hogset.
    func relinkSongPanel() {
        guard project.songPath != nil, editingState == nil else { importSongPanel(); return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mp3, .wav, .aiff, .mpeg4Audio, .audio]
        panel.message = "Select the audio file for “\(project.name)”"
        if let old = project.songPath {
            let dir = URL(fileURLWithPath: old).deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: dir.path) { panel.directoryURL = dir }
        }
        if panel.runModal() == .OK, let url = panel.url { relinkSong(to: url) }
    }

    func relinkSong(to url: URL) {
        project.songPath = url.path
        settings.remember(song: url.path)
        decodedAudio = nil
        reloadPlayer()
        if let analysed = project.analysis?.duration, duration > 0, abs(analysed - duration) > 1 {
            analysisStatus = String(format: "Linked %@ — its length (%@) differs from the analysis (%@). Re-analyze if this is a different version.",
                                    url.lastPathComponent, formatTime(duration), formatTime(analysed))
        } else {
            analysisStatus = "Linked \(url.lastPathComponent)"
        }
    }

    // MARK: - Setlist songs (rename / relink / analyse any song, not only the selected one)

    /// Changes the display name of a setlist song. The audio file name is not touched.
    func renameSong(_ id: UUID, to newName: String) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if selection == .song(id) {
            project.name = name            // written back to the setlist by project.didSet
        } else {
            updateSetlist { set in
                if let i = set.songs.firstIndex(where: { $0.id == id }) { set.songs[i].project.name = name }
            }
        }
    }

    /// Asks for a new display name (right-click › Rename Song… in the setlist).
    func renameSongPrompt(_ id: UUID) {
        guard let song = setlist?.songs.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Song"
        alert.informativeText = "This is the name shown in Mac2Hog. The audio file is not renamed."
        let field = NSTextField(string: song.name)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn { renameSong(id, to: field.stringValue) }
    }

    /// Select File… for any setlist song: replaces only its audio path (no re-analysis).
    func relinkSongPanel(_ id: UUID) {
        if selection == .song(id) { relinkSongPanel(); return }
        guard let song = setlist?.songs.first(where: { $0.id == id }) else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mp3, .wav, .aiff, .mpeg4Audio, .audio]
        panel.message = "Select the audio file for “\(song.name)”"
        if let old = song.project.songPath {
            let dir = URL(fileURLWithPath: old).deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: dir.path) { panel.directoryURL = dir }
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        updateSetlist { set in
            if let i = set.songs.firstIndex(where: { $0.id == id }) { set.songs[i].project.songPath = url.path }
        }
        settings.remember(song: url.path)
        analysisStatus = "Linked \(url.lastPathComponent) to “\(song.name)”"
    }

    /// Re-analyses any setlist song; the result is stored on that song.
    func analyzeSong(_ id: UUID) {
        if selection == .song(id) { analyze(); return }
        guard let path = setlist?.songs.first(where: { $0.id == id })?.project.songPath else { return }
        runAnalysis(path: path, target: .song(id), cached: nil, completion: nil)
    }

    var currentSongMissing: Bool {
        guard let path = project.songPath else { return false }
        return !FileManager.default.fileExists(atPath: path)
    }

    func reloadPlayer() {
        guard let path = project.songPath, FileManager.default.fileExists(atPath: path) else {
            // Missing files are flagged in the sidebar and Settings › Song (Select File… reconnects them).
            engine.load(player: nil); duration = 0; refreshTransport(); return
        }
        let url = URL(fileURLWithPath: path)
        do {
            let player: AVAudioPlayer
            if settings.ltcOnRightChannel {
                let audio = try decodedAudio ?? AudioDecoder.decode(url: url)
                decodedAudio = audio
                let ltc = LTCEncoder.render(start: project.timecodeStart, duration: audio.duration,
                                            sampleRate: audio.sampleRate, amplitude: 0.4)
                var stereo = [Float](repeating: 0, count: audio.samples.count * 2)
                for i in 0..<audio.samples.count {
                    stereo[2 * i] = audio.samples[i]
                    stereo[2 * i + 1] = i < ltc.count ? ltc[i] : 0
                }
                player = try AVAudioPlayer(data: WAVDecoder.encode16(samples: stereo, sampleRate: Int(audio.sampleRate), channels: 2))
            } else {
                player = try AVAudioPlayer(contentsOf: url)
            }
            engine.load(player: player)
            duration = player.duration
            refreshTransport()
        } catch {
            alertMessage = "Could not open \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func analyze(completion: (() -> Void)? = nil) {
        guard let path = project.songPath else { return }
        runAnalysis(path: path, target: selection, cached: decodedAudio, completion: completion)
    }

    /// Analyzes `path`; the result goes to the song identified by `target` (nil = single-song project).
    private func runAnalysis(path: String, target: SetlistSelection?, cached: MonoAudio?, completion: (() -> Void)?) {
        guard !isAnalyzing else { return }
        let url = URL(fileURLWithPath: path)
        let options = settings.analyzerOptions
        isAnalyzing = true
        analysisProgress = 0
        analysisStatus = "Decoding audio"
        // AppState is main-actor isolated (Sendable) and lives as long as the app, so a strong capture is fine.
        Task.detached(priority: .userInitiated) { [self] in
            do {
                let audio = try cached ?? AudioDecoder.decode(url: url)
                let result = AudioAnalyzer(options: options).analyze(audio) { p, status in
                    Task { @MainActor in self.analysisProgress = p; self.analysisStatus = status }
                }
                await MainActor.run {
                    self.isAnalyzing = false
                    // The user may have switched to another setlist song meanwhile: store it on the right one.
                    if self.selection != target, case .song(let id)? = target, var set = self.setlist,
                       let i = set.songs.firstIndex(where: { $0.id == id }) {
                        set.songs[i].project.analysis = result
                        if set.songs[i].project.triggers.isEmpty { set.songs[i].project.triggers = TriggerGenerator().generate(from: result) }
                        self.setlist = set
                        completion?()
                        return
                    }
                    self.decodedAudio = audio
                    self.project.analysis = result
                    self.analysisStatus = "Tempo \(String(format: "%.1f", result.bpm)) BPM · \(result.sections.count) sections · \(result.snares.count) snare hits · \(result.breaks.count) breaks"
                    if self.project.triggers.isEmpty {
                        self.project.triggers = TriggerGenerator().generate(from: result)
                    }
                    completion?()
                }
            } catch {
                await MainActor.run {
                    self.isAnalyzing = false
                    self.analysisStatus = "Analysis failed"
                    self.alertMessage = "\(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }
    }

    /// Applies a user-corrected tempo as a constant grid anchored on the first detected downbeat.
    func applyTempo(_ bpm: Double) {
        guard var a = project.analysis, bpm > 20, bpm < 400 else { return }
        let anchor = a.downbeats.first(where: { $0.time >= 0 })?.time ?? 0
        a.applyFixedGrid(bpm: bpm, firstDownbeat: anchor)
        project.analysis = a
    }

    func shiftDownbeat(by beats: Int) {
        guard var a = project.analysis, let first = a.downbeats.first else { return }
        a.applyFixedGrid(bpm: a.bpm, firstDownbeat: first.time + Double(beats) * 60 / a.bpm)
        project.analysis = a
    }

    // MARK: - Showfile

    func importShowfilePanel() {
        let panel = NSOpenPanel()
        var types: [UTType] = [.xml, .commaSeparatedText, .plainText, .json]
        for ext in ["shw", "hog4", "tsv"] { if let t = UTType(filenameExtension: ext) { types.append(t) } }
        panel.allowedContentTypes = types
        panel.allowsOtherFileTypes = true
        panel.message = "Choose a Hog show export (.xml), a CSV list, or a show file"
        if panel.runModal() == .OK, let url = panel.url { loadShowfile(url) }
    }

    func loadShowfile(_ url: URL, remember: Bool = true) {
        do {
            let show = try ShowfileImporter.importShow(from: url)
            currentShow = show
            project.show = show
            if var set = setlist {
                for i in set.songs.indices { set.songs[i].project.show = show }
                setlist = set
            }
            if remember {
                settings.remember(showfile: url.path)
                settings.selectedShowfile = url.path
            }
        } catch {
            alertMessage = "\(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    // MARK: - Triggers

    var selectedTrigger: ShowTrigger? {
        get { project.triggers.first { $0.id == selectedTriggerID } }
    }

    func binding(for id: UUID) -> Binding<ShowTrigger>? {
        guard project.triggers.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { [weak self] in self?.project.triggers.first { $0.id == id } ?? ShowTrigger(time: 0, name: "") },
            set: { [weak self] new in
                guard let self, let i = self.project.triggers.firstIndex(where: { $0.id == id }) else { return }
                self.project.triggers[i] = new
            })
    }

    @discardableResult
    func addTrigger(at time: Double, name: String? = nil, source: TriggerSource = .manual) -> ShowTrigger {
        if editingState != nil {
            // State cue lists have no song: new cues follow the previous one.
            let first = project.triggers.isEmpty
            let trigger = ShowTrigger(time: 0, name: name ?? "Cue \(project.triggers.count + 1)", source: .manual,
                                      startMode: first ? .timecode : .follow, delay: 0)
            project.triggers.append(trigger)
            selectedTriggerID = trigger.id
            return trigger
        }
        var t = time
        if snapToBeat, source == .manual, let a = project.analysis { t = TriggerGenerator.snap(time, to: a, subdivision: 2) }
        let trigger = ShowTrigger(time: max(0, t), name: name ?? "Cue \(project.triggers.count + 1)", source: source)
        project.triggers.append(trigger)
        selectedTriggerID = trigger.id
        return trigger
    }

    func deleteTriggers(_ ids: Set<UUID>) {
        project.triggers.removeAll { ids.contains($0.id) }
        if let s = selectedTriggerID, ids.contains(s) { selectedTriggerID = nil }
    }

    func duplicateTrigger(_ id: UUID) {
        guard let t = project.triggers.first(where: { $0.id == id }) else { return }
        var copy = t
        copy.id = UUID()
        copy.commands = t.commands.map { $0.withNewID() }
        copy.name += " copy"
        if copy.startMode == .timecode { copy.time += 60 / (project.analysis?.bpm ?? 120) }
        if let i = project.triggers.firstIndex(where: { $0.id == id }) { project.triggers.insert(copy, at: i + 1) } else { project.triggers.append(copy) }
        selectedTriggerID = copy.id
    }

    func generateTriggers(_ generator: TriggerGenerator, replace: Bool) {
        guard let a = project.analysis else { return }
        let generated = generator.generate(from: a)
        if replace { project.triggers = generated } else { project.triggers = project.triggers + generated }
    }

    /// Copies a command to every trigger of the same source (e.g. all snares).
    func applyCommandsToAll(from id: UUID) {
        guard let t = project.triggers.first(where: { $0.id == id }) else { return }
        for i in project.triggers.indices where project.triggers[i].source == t.source && project.triggers[i].id != id {
            project.triggers[i].commands = t.commands.map { $0.withNewID() }
        }
    }

    /// Adds a predefined trigger's commands to a cue.
    func apply(_ predefined: PredefinedTrigger, to id: UUID) {
        binding(for: id)?.wrappedValue.commands.append(contentsOf: predefined.instantiate())
    }

    /// Saves a cue's commands as a new predefined trigger (Settings › Predefined).
    func saveAsPredefined(_ trigger: ShowTrigger) {
        let p = PredefinedTrigger(name: trigger.name, commands: trigger.commands.map { $0.withNewID() })
        settings.predefinedTriggers.append(p)
    }

    // MARK: - Documents

    func newProject() {
        guard confirmDiscard() else { return }
        stop()
        setlist = nil
        selection = nil
        project = ShowProject(timecodeRate: settings.timecodeRate, timecodeStart: Timecode(hours: settings.timecodeStartHour, rate: settings.timecodeRate),
                              show: currentShow ?? project.show)
        projectURL = nil
        decodedAudio = nil
        reloadPlayer()
        isDirty = false
    }

    func newSetlist() {
        guard confirmDiscard() else { return }
        stop()
        selection = nil
        projectURL = nil
        autosaveName = UUID().uuidString
        setlist = Setlist()
        selectInternal(.state(.starting))
        isDirty = false
    }

    func openProjectPanel() {
        guard confirmDiscard() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ShowProject.fileExtension) ?? .json,
                                     UTType(filenameExtension: Setlist.fileExtension) ?? .json, .json]
        if panel.runModal() == .OK, let url = panel.url { openProject(url) }
    }

    func openProject(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            stop()
            if url.pathExtension.lowercased() == Setlist.fileExtension, let set = try? Setlist.decode(data) {
                setlist = set
                selection = nil
                projectURL = url
                if let show = set.songs.compactMap(\.project.show).first { currentShow = show }
                selectInternal(set.songs.first.map { .song($0.id) } ?? .state(.starting))
                let missing = set.songs.compactMap(\.project.songPath).filter { !FileManager.default.fileExists(atPath: $0) }
                if !missing.isEmpty {
                    alertMessage = "These songs could not be found:\n" + missing.joined(separator: "\n")
                        + "\n\nSelect each song in the setlist and use Settings › Song › Select File… to reconnect it."
                }
                isDirty = false
                return
            }
            let p = try ShowProject.decode(data)
            setlist = nil
            selection = nil
            project = p
            projectURL = url
            decodedAudio = nil
            if let show = p.show { currentShow = show }
            settings.timecodeRate = p.timecodeRate
            settings.timecodeStartHour = p.timecodeStart.hours
            if let path = p.songPath, !FileManager.default.fileExists(atPath: path) {
                alertMessage = "The song \(path) could not be found. Use Settings › Song › Select File… to reconnect it."
            }
            reloadPlayer()
            isDirty = false
        } catch {
            alertMessage = "Could not open show: \(error.localizedDescription)"
        }
    }

    private var documentExtension: String { setlist != nil ? Setlist.fileExtension : ShowProject.fileExtension }

    func saveProject() {
        guard let url = projectURL, url.pathExtension.lowercased() == documentExtension else { saveProjectAs(); return }
        do {
            if let set = setlist { try set.encoded().write(to: url, options: .atomic) }
            else { try project.encoded().write(to: url, options: .atomic) }
            isDirty = false
        } catch { alertMessage = "Save failed: \(error.localizedDescription)" }
    }

    func saveProjectAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: documentExtension) ?? .json]
        panel.nameFieldStringValue = "\(setlist?.name ?? project.name).\(documentExtension)"
        if panel.runModal() == .OK, let url = panel.url { projectURL = url; saveProject() }
    }

    private func confirmDiscard() -> Bool {
        let hasContent = !project.triggers.isEmpty || !(setlist?.songs.isEmpty ?? true)
        guard isDirty, hasContent else { return true }
        let alert = NSAlert()
        alert.messageText = "Discard unsaved changes to “\(setlist?.name ?? project.name)”?"
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Auto-save

    /// Folder where setlists that were never saved by the user are auto-saved.
    static var autosaveFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("Mac2Hog/Autosave", isDirectory: true)
    }

    /// Setlists auto-save after every change (debounced): to their own `.mac2hogset` file once saved,
    /// otherwise to the Autosave folder. Single-song shows auto-save once they have a file.
    private func scheduleAutosave() {
        guard setlist != nil || projectURL != nil else { return }
        autosaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.autosave() }
        autosaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func autosave() {
        let data: Data
        let url: URL
        do {
            if let set = setlist {
                data = try set.encoded()
                if let u = projectURL, u.pathExtension.lowercased() == Setlist.fileExtension {
                    url = u
                } else {
                    try FileManager.default.createDirectory(at: Self.autosaveFolder, withIntermediateDirectories: true)
                    let safe = set.name.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
                    url = Self.autosaveFolder.appendingPathComponent("\(safe) \(autosaveName.prefix(8)).\(Setlist.fileExtension)")
                }
            } else if let u = projectURL, u.pathExtension.lowercased() == ShowProject.fileExtension {
                data = try project.encoded()
                url = u
            } else { return }
        } catch {
            alertMessage = "Auto-save failed: \(error.localizedDescription)"
            return
        }
        let savedToDocument = url == projectURL
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let ok = (try? data.write(to: url, options: .atomic)) != nil
            DispatchQueue.main.async {
                guard let self, ok else { return }
                self.lastAutosave = Date()
                if savedToDocument { self.isDirty = false }
            }
        }
    }

    func showAutosaveFolder() {
        try? FileManager.default.createDirectory(at: Self.autosaveFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.autosaveFolder)
    }

    // MARK: - Setlist editing

    /// Switches the editor to a song or state of the setlist (not while the setlist is running).
    func select(_ sel: SetlistSelection) {
        guard !phase.isRunning else { return }
        selectInternal(sel)
    }

    private func selectInternal(_ sel: SetlistSelection) {
        guard let set = setlist else { return }
        let wasDirty = isDirty
        engine.stop()
        selectedTriggerID = nil
        selection = sel
        decodedAudio = nil
        switch sel {
        case .song(let id):
            guard let song = set.songs.first(where: { $0.id == id }) else { return }
            project = song.project
            if project.show == nil, let show = currentShow { project.show = show }
            reloadPlayer()
        case .state(let st):
            project = ShowProject(name: st.displayName, timecodeRate: settings.timecodeRate,
                                  timecodeStart: Timecode(rate: settings.timecodeRate),
                                  triggers: set.cues(for: st), show: currentShow)
            engine.load(player: nil)
            duration = 0
        }
        cueStack.reset()
        isDirty = wasDirty
        refreshTransport()
    }

    private func writeBackToSetlist() {
        guard var set = setlist, let sel = selection else { return }
        switch sel {
        case .song(let id):
            guard let i = set.songs.firstIndex(where: { $0.id == id }) else { return }
            set.songs[i].project = project
        case .state(let st):
            set.setCues(project.triggers, for: st)
        }
        setlist = set
    }

    func addSongsToSetlistPanel() {
        if setlist == nil { newSetlist() }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mp3, .wav, .aiff, .mpeg4Audio, .audio]
        panel.allowsMultipleSelection = true
        panel.message = "Choose one or more songs to add to the setlist"
        guard panel.runModal() == .OK else { return }
        addSongs(panel.urls)
    }

    func addSongs(_ urls: [URL]) {
        guard var set = setlist, !urls.isEmpty else { return }
        var added: [SetlistSong] = []
        for url in urls {
            var p = ShowProject(name: url.deletingPathExtension().lastPathComponent, songPath: url.path,
                                timecodeRate: settings.timecodeRate,
                                timecodeStart: Timecode(hours: settings.timecodeStartHour, rate: settings.timecodeRate))
            p.show = currentShow
            added.append(SetlistSong(project: p))
            settings.remember(song: url.path)
        }
        set.songs += added
        setlist = set
        isDirty = true
        selectInternal(.song(added[0].id))
        analyzeAllUnanalyzed()
    }

    func removeSongs(_ ids: Set<UUID>) {
        guard var set = setlist, !phase.isRunning else { return }
        set.songs.removeAll { ids.contains($0.id) }
        setlist = set
        isDirty = true
        if case .song(let id)? = selection, ids.contains(id) {
            selectInternal(set.songs.first.map { .song($0.id) } ?? .state(.starting))
        }
    }

    func moveSongs(from offsets: IndexSet, to destination: Int) {
        guard var set = setlist, !phase.isRunning else { return }
        set.songs.move(fromOffsets: offsets, toOffset: destination)
        setlist = set
        isDirty = true
    }

    func updateSetlist(_ change: (inout Setlist) -> Void) {
        guard var set = setlist else { return }
        change(&set)
        setlist = set
        isDirty = true
    }

    /// Analyzes the songs of the setlist that have no analysis yet, one after another.
    func analyzeAllUnanalyzed() {
        guard let set = setlist, !isAnalyzing else { return }
        // Current song first, then the rest in setlist order.
        let ordered = (currentSongIndex.map { [set.songs[$0]] } ?? []) + set.songs
        guard let next = ordered.first(where: {
                  $0.project.analysis == nil && $0.project.songPath.map { FileManager.default.fileExists(atPath: $0) } == true
              }),
              let path = next.project.songPath else { return }
        let isCurrent = selection == .song(next.id)
        runAnalysis(path: path, target: .song(next.id), cached: isCurrent ? decodedAudio : nil) { [weak self] in
            self?.analyzeAllUnanalyzed()
        }
    }

    // MARK: - Setlist playback

    /// Starts the setlist. `index` < 0 starts with the Starting state, otherwise at that song.
    func startSetlist(from index: Int) {
        guard let set = setlist, !set.songs.isEmpty else { alertMessage = "Add songs to the setlist first."; return }
        stop()
        if index <= 0 {
            engine.runSequence(set.startingState)
            let delay = max(set.startDelay, 0)
            phase = .starting(until: Date().addingTimeInterval(delay))
            schedulePhase(after: delay) { [weak self] in self?.startSong(at: 0) }
        } else {
            startSong(at: min(index, set.songs.count - 1))
        }
    }

    func startSong(at index: Int) {
        guard let set = setlist, set.songs.indices.contains(index) else { return }
        phaseWork?.cancel()
        engine.cancelScheduled()
        selectInternal(.song(set.songs[index].id))
        phase = .song(index: index)
        engine.seek(to: 0)
        if mode == .timecode { play() }
    }

    private func songFinished() {
        guard let set = setlist, case .song(let i) = phase else { return }
        if i + 1 < set.songs.count {
            engine.runSequence(set.waitingState)
            if set.autoAdvance {
                let gap = set.gap(after: i)
                phase = .waiting(afterIndex: i, until: Date().addingTimeInterval(gap))
                schedulePhase(after: gap) { [weak self] in self?.startSong(at: i + 1) }
            } else {
                phase = .waiting(afterIndex: i, until: nil)
            }
        } else {
            engine.runSequence(set.endingState)
            phase = .ending
            schedulePhase(after: CueTiming.length(of: set.endingState) + 0.5) { [weak self] in self?.phase = .finished }
        }
    }

    private func schedulePhase(after seconds: Double, _ action: @escaping () -> Void) {
        phaseWork?.cancel()
        let work = DispatchWorkItem(block: action)
        phaseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Human readable status of a running setlist for the transport bar.
    var phaseDescription: String? {
        guard let set = setlist else { return nil }
        func countdown(_ d: Date) -> String { String(format: "%.0f s", max(0, d.timeIntervalSince(clock))) }
        switch phase {
        case .idle: return nil
        case .starting(let until): return "Starting state · first song in \(countdown(until))"
        case .song(let i): return "Song \(i + 1) of \(set.songs.count): \(set.songs[i].name)"
        case .waiting(let i, let until):
            let next = set.songs.indices.contains(i + 1) ? set.songs[i + 1].name : ""
            return until.map { "Waiting state · \(next) in \(countdown($0))" } ?? "Waiting state · press Play for \(next)"
        case .ending: return "Ending state"
        case .finished: return "Setlist finished"
        }
    }

    func exportCueSheet() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(project.name) cues.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try project.cueSheetCSV(mapper: mapper).write(to: url, atomically: true, encoding: .utf8) }
        catch { alertMessage = error.localizedDescription }
    }

    func exportLTC(includeSong: Bool) {
        guard let path = project.songPath else { alertMessage = "Import a song first."; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = "\(project.name) \(includeSong ? "song+LTC" : "LTC").wav"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let audio = try decodedAudio ?? AudioDecoder.decode(url: URL(fileURLWithPath: path))
            decodedAudio = audio
            let rate = 48_000.0
            let ltc = LTCEncoder.render(start: project.timecodeStart, duration: audio.duration, sampleRate: includeSong ? audio.sampleRate : rate)
            let data: Data
            if includeSong {
                var stereo = [Float](repeating: 0, count: audio.samples.count * 2)
                for i in 0..<audio.samples.count { stereo[2 * i] = audio.samples[i]; stereo[2 * i + 1] = i < ltc.count ? ltc[i] : 0 }
                data = WAVDecoder.encode16(samples: stereo, sampleRate: Int(audio.sampleRate), channels: 2)
            } else {
                data = WAVDecoder.encode16(samples: ltc, sampleRate: Int(rate))
            }
            try data.write(to: url)
        } catch { alertMessage = error.localizedDescription }
    }
}

extension CueStack {
    /// Rebuilds the stack after edits while keeping the "next" cue where it was.
    init(triggers: [ShowTrigger], keeping old: CueStack) {
        self.init(triggers: triggers)
        if let next = old.next { select(id: next.id) } else if old.isFinished && !old.cues.isEmpty { select(index: cues.count) }
    }
}
#endif
