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
            if settings.timecodeRate != oldValue.timecodeRate || settings.timecodeStartHour != oldValue.timecodeStartHour {
                project.timecodeRate = settings.timecodeRate
                project.timecodeStart = Timecode(hours: settings.timecodeStartHour, rate: settings.timecodeRate)
            }
        }
    }

    // MARK: Show document
    @Published var project = ShowProject() {
        didSet { engine.setTriggers(project.triggers); cueStack = CueStack(triggers: project.triggers, keeping: cueStack) ; isDirty = true }
    }
    @Published var projectURL: URL?
    @Published var isDirty = false

    // MARK: Playback
    @Published var mode: PlaybackMode = .timecode {
        didSet { engine.setAutoFire(mode == .timecode); if mode == .manual { cueStack.reset() } }
    }
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: Double = 0
    @Published var cueStack = CueStack(triggers: [])
    @Published var lastFiredID: UUID?

    // MARK: Analysis
    @Published private(set) var isAnalyzing = false
    @Published private(set) var analysisProgress: Double = 0
    @Published private(set) var analysisStatus = ""
    private var decodedAudio: MonoAudio?

    // MARK: UI
    @Published var selectedTriggerID: UUID?
    @Published var log: [OSCLogEntry] = []
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
        configureNetwork()
        configureFeedback()
        if let path = settings.selectedShowfile, FileManager.default.fileExists(atPath: path) {
            loadShowfile(URL(fileURLWithPath: path), remember: false)
        }
        keyMonitor.start(onSpace: { [weak self] in self?.spacePressed() },
                         onEscape: { [weak self] in self?.stop() })
        uiTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshTransport() }
        }
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
        if let t = event.trigger { lastFiredID = t.id }
        let title = event.trigger.map { "\(project.timecode(at: event.songTime))  \($0.name)" } ?? "OSC"
        let detail = event.messages.isEmpty ? "(no commands)" : event.messages.map(\.description).joined(separator: "   ")
        appendLog(OSCLogEntry(songTime: event.songTime, title: title, detail: event.error.map { "\(detail)  ⚠︎ \($0)" } ?? detail,
                              isError: event.error != nil, incoming: false))
        if event.error != nil { networkOK = false; networkStatus = event.error ?? "" } else if !event.messages.isEmpty { networkOK = true }
    }

    private func appendLog(_ entry: OSCLogEntry) {
        log.append(entry)
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    // MARK: - Transport

    private func refreshTransport() {
        let t = engine.currentTime
        if abs(t - currentTime) > 0.001 { currentTime = t }
        let playing = engine.isPlaying
        if playing != isPlaying { isPlaying = playing }
    }

    var currentTimecode: Timecode { project.timecode(at: currentTime) }

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard engine.hasAudio else { alertMessage = "Import a song first."; return }
        engine.play()
        refreshTransport()
    }

    func pause() { engine.pause(); refreshTransport() }

    func stop() {
        engine.stop()
        if settings.sendReleaseOnStop {
            var seen = Set<String>()
            let releases = project.triggers.flatMap(\.commands).filter(\.action.usesObject).compactMap { c -> HogCommand? in
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
        guard let cue = cueStack.go() else { NSSound.beep(); return }
        engine.fire(cue)
        selectedTriggerID = cue.id
        // Follow along in the song so the waveform shows where we are.
        if !isPlaying && engine.hasAudio { seek(to: cue.time) }
    }

    func backCue() {
        if let cue = cueStack.back() {
            engine.fire(cue)
            selectedTriggerID = cue.id
        }
    }

    func setNextCue(_ id: UUID) { cueStack.select(id: id) }

    func fire(_ trigger: ShowTrigger) { engine.fire(trigger) }

    // MARK: - Song import & analysis

    func importSongPanel() {
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

    func reloadPlayer() {
        guard let path = project.songPath else { engine.load(player: nil); duration = 0; return }
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

    func analyze() {
        guard let path = project.songPath, !isAnalyzing else { return }
        let url = URL(fileURLWithPath: path)
        let options = settings.analyzerOptions
        let cached = decodedAudio
        isAnalyzing = true
        analysisProgress = 0
        analysisStatus = "Decoding audio"
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let audio = try cached ?? AudioDecoder.decode(url: url)
                let result = AudioAnalyzer(options: options).analyze(audio) { p, status in
                    Task { @MainActor in self?.analysisProgress = p; self?.analysisStatus = status }
                }
                await MainActor.run {
                    guard let self else { return }
                    self.decodedAudio = audio
                    self.project.analysis = result
                    self.isAnalyzing = false
                    self.analysisStatus = "Tempo \(String(format: "%.1f", result.bpm)) BPM · \(result.sections.count) sections · \(result.snares.count) snare hits · \(result.breaks.count) breaks"
                    if self.project.triggers.isEmpty {
                        self.project.triggers = TriggerGenerator().generate(from: result)
                    }
                }
            } catch {
                await MainActor.run {
                    self?.isAnalyzing = false
                    self?.analysisStatus = "Analysis failed"
                    self?.alertMessage = error.localizedDescription
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
        panel.message = "Choose a Hog 4 show export (.xml), a CSV list, or a show file"
        if panel.runModal() == .OK, let url = panel.url { loadShowfile(url) }
    }

    func loadShowfile(_ url: URL, remember: Bool = true) {
        do {
            let show = try ShowfileImporter.importShow(from: url)
            project.show = show
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
        var t = time
        if snapToBeat, source == .manual, let a = project.analysis { t = TriggerGenerator.snap(time, to: a, subdivision: 2) }
        let trigger = ShowTrigger(time: max(0, t), name: name ?? "Cue \(project.triggers.count + 1)", source: source)
        project.triggers.append(trigger)
        project.triggers.sort { $0.time < $1.time }
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
        copy.time += 60 / (project.analysis?.bpm ?? 120)
        project.triggers.append(copy)
        project.triggers.sort { $0.time < $1.time }
        selectedTriggerID = copy.id
    }

    func generateTriggers(_ generator: TriggerGenerator, replace: Bool) {
        guard let a = project.analysis else { return }
        let generated = generator.generate(from: a)
        if replace { project.triggers = generated } else { project.triggers = (project.triggers + generated).sorted { $0.time < $1.time } }
    }

    /// Copies a command to every trigger of the same source (e.g. all snares).
    func applyCommandsToAll(from id: UUID) {
        guard let t = project.triggers.first(where: { $0.id == id }) else { return }
        for i in project.triggers.indices where project.triggers[i].source == t.source && project.triggers[i].id != id {
            project.triggers[i].commands = t.commands.map { $0.withNewID() }
        }
    }

    // MARK: - Documents

    func newProject() {
        guard confirmDiscard() else { return }
        engine.stop()
        project = ShowProject(timecodeRate: settings.timecodeRate, timecodeStart: Timecode(hours: settings.timecodeStartHour, rate: settings.timecodeRate),
                              show: project.show)
        projectURL = nil
        decodedAudio = nil
        reloadPlayer()
        isDirty = false
    }

    func openProjectPanel() {
        guard confirmDiscard() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ShowProject.fileExtension) ?? .json, .json]
        if panel.runModal() == .OK, let url = panel.url { openProject(url) }
    }

    func openProject(_ url: URL) {
        do {
            let p = try ShowProject.decode(Data(contentsOf: url))
            project = p
            projectURL = url
            decodedAudio = nil
            settings.timecodeRate = p.timecodeRate
            settings.timecodeStartHour = p.timecodeStart.hours
            if let path = p.songPath, !FileManager.default.fileExists(atPath: path) {
                alertMessage = "The song \(path) could not be found. Use File › Import Song to relink it."
            }
            reloadPlayer()
            isDirty = false
        } catch {
            alertMessage = "Could not open show: \(error.localizedDescription)"
        }
    }

    func saveProject() {
        guard let url = projectURL else { saveProjectAs(); return }
        do {
            try project.encoded().write(to: url, options: .atomic)
            isDirty = false
        } catch { alertMessage = "Save failed: \(error.localizedDescription)" }
    }

    func saveProjectAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ShowProject.fileExtension) ?? .json]
        panel.nameFieldStringValue = "\(project.name).\(ShowProject.fileExtension)"
        if panel.runModal() == .OK, let url = panel.url { projectURL = url; saveProject() }
    }

    private func confirmDiscard() -> Bool {
        guard isDirty, !project.triggers.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "Discard unsaved changes to “\(project.name)”?"
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
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
