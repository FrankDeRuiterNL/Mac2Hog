#if os(macOS)
import Foundation
import AVFoundation
import Mac2HogCore

/// Real-time part of the app: audio playback, a 4 ms timecode clock and OSC output.
/// Triggers fire on a dedicated high-priority queue so UI work never delays a cue.
final class ShowEngine: @unchecked Sendable {
    struct FireEvent {
        var trigger: ShowTrigger?
        var messages: [OSCMessage]
        var error: String?
        var songTime: Double
        /// Log title for delayed commands (e.g. "Cue 3 · Release Cuelist 1 (Follow +5s)").
        var label: String?
    }

    private let queue = DispatchQueue(label: "mac2hog.engine", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var player: AVAudioPlayer?
    private var runner = ShowRunner(triggers: [])
    private var sender: OSCSender?
    private var mapper = HogOSCMapper()
    private var milluminSender: OSCSender?
    private var milluminMapper = MilluminOSCMapper()
    private var autoFire = true
    private var scheduled: [DispatchWorkItem] = []
    private let playerDelegate = PlayerDelegate()

    /// Delivered on the main queue.
    var onFire: ((FireEvent) -> Void)?
    /// Called on the main queue when the song plays to its end (not on stop).
    var onSongFinished: (() -> Void)? {
        get { playerDelegate.onFinish }
        set { playerDelegate.onFinish = newValue }
    }

    init() {
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .microseconds(500))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    deinit { timer?.cancel() }

    // MARK: Configuration

    func configure(host: String, port: UInt16, interface: String?, mapper: HogOSCMapper, latency: Double) throws {
        let newSender = try OSCSender(host: host, port: port, interface: interface)
        queue.sync {
            self.sender = newSender
            self.mapper = mapper
            self.runner.latencyCompensation = latency
        }
    }

    /// Millumin destination for "Millumin Custom OSC" commands; an empty host disables it.
    func configureMillumin(host: String, port: UInt16, interface: String?, mapper: MilluminOSCMapper) throws {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        let newSender = trimmed.isEmpty ? nil : try OSCSender(host: trimmed, port: port, interface: interface)
        queue.sync {
            self.milluminSender = newSender
            self.milluminMapper = mapper
        }
    }

    func setTriggers(_ triggers: [ShowTrigger]) {
        queue.async { self.runner.update(triggers: triggers) }
    }

    func setAutoFire(_ enabled: Bool) {
        queue.async { self.autoFire = enabled }
    }

    // MARK: Transport (call from main)

    /// Second player carrying the LTC timecode on its own output device; follows the song player.
    private var ltcPlayer: AVAudioPlayer?

    func load(player: AVAudioPlayer?, ltc: AVAudioPlayer? = nil) {
        ltcPlayer?.stop()
        ltcPlayer = ltc
        ltcPlayer?.prepareToPlay()
        queue.sync {
            self.player?.stop()
            self.player = player
            self.player?.delegate = self.playerDelegate
            self.player?.prepareToPlay()
            self.runner.reset()
        }
    }

    var hasAudio: Bool { player != nil }
    var duration: Double { player?.duration ?? 0 }
    var currentTime: Double { player?.currentTime ?? 0 }
    var isPlaying: Bool { player?.isPlaying ?? false }

    func play() {
        guard let p = player else { return }
        queue.sync { runner.seek(to: p.currentTime) }
        if let ltc = ltcPlayer {
            // Start both players at the same moment (slightly in the future) so the timecode lines up.
            ltc.currentTime = min(p.currentTime, ltc.duration)
            let lead = 0.05
            p.play(atTime: p.deviceCurrentTime + lead)
            ltc.play(atTime: ltc.deviceCurrentTime + lead)
        } else {
            p.play()
        }
    }

    func pause() {
        player?.pause()
        ltcPlayer?.pause()
    }

    func stop() {
        cancelScheduled()
        player?.stop()
        player?.currentTime = 0
        ltcPlayer?.stop()
        ltcPlayer?.currentTime = 0
        queue.sync { runner.seek(to: 0) }
    }

    func seek(to time: Double) {
        guard let p = player else { return }
        let t = max(0, min(time, p.duration))
        let wasPlaying = p.isPlaying
        p.currentTime = t
        if let ltc = ltcPlayer {
            ltc.currentTime = min(t, ltc.duration)
            // Re-align the timecode with the song after a jump.
            if wasPlaying { ltc.pause(); p.pause(); play() }
        }
        queue.sync { runner.seek(to: t) }
    }

    // MARK: Output

    /// Sends a trigger's commands immediately (manual GO, test buttons).
    func fire(_ trigger: ShowTrigger) {
        queue.async {
            let event = self.send(trigger: trigger, at: self.player?.currentTime ?? 0)
            DispatchQueue.main.async { self.onFire?(event) }
        }
    }

    /// Fires cues after the given delays (seconds from now): Follow / Wait chains and state sequences.
    func schedule(_ items: [(trigger: ShowTrigger, delay: Double)]) {
        queue.async { [weak self] in
            guard let self else { return }
            for item in items {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    let event = self.send(trigger: item.trigger, at: self.player?.currentTime ?? 0)
                    DispatchQueue.main.async { self.onFire?(event) }
                }
                self.scheduled.append(work)
                self.queue.asyncAfter(deadline: .now() + max(0, item.delay), execute: work)
            }
        }
    }

    /// Runs a state's cue list; cue times are seconds from now.
    func runSequence(_ cues: [ShowTrigger]) {
        var ordered = cues
        CueTiming.normalize(&ordered)
        schedule(ordered.filter(\.enabled).map { (trigger: $0, delay: $0.time) })
    }

    func cancelScheduled() {
        queue.async {
            self.scheduled.forEach { $0.cancel() }
            self.scheduled.removeAll()
        }
    }

    func send(commands: [HogCommand]) {
        fire(ShowTrigger(time: player?.currentTime ?? 0, name: "Test", commands: commands))
    }

    func send(raw message: OSCMessage) {
        queue.async {
            var errorText: String?
            if let s = self.sender {
                do { try s.send(message) } catch let e { errorText = e.localizedDescription }
            } else {
                errorText = "Console address not configured"
            }
            let ev = FireEvent(trigger: nil, messages: [message], error: errorText, songTime: self.player?.currentTime ?? 0)
            DispatchQueue.main.async { self.onFire?(ev) }
        }
    }

    /// Sends a cue's immediate commands now and schedules its delayed (Follow / Wait) commands.
    /// Must run on `queue`.
    private func send(trigger: ShowTrigger, at time: Double) -> FireEvent {
        let now = trigger.commands.filter { $0.timing == nil }
        for command in trigger.commands {
            guard let timing = command.timing else { continue }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let (messages, error) = self.transmit([command])
                let event = FireEvent(trigger: nil, messages: messages, error: error,
                                      songTime: self.player?.currentTime ?? 0,
                                      label: "\(trigger.name) · \(command.summary)")
                DispatchQueue.main.async { self.onFire?(event) }
            }
            scheduled.append(work)
            queue.asyncAfter(deadline: .now() + timing.delay(cueDuration: trigger.duration), execute: work)
        }
        let (messages, error) = transmit(now)
        return FireEvent(trigger: trigger, messages: messages, error: error, songTime: time)
    }

    /// Hog commands go to the console, Millumin commands to Millumin.
    private func transmit(_ commands: [HogCommand]) -> ([OSCMessage], String?) {
        let hog = commands.filter { !$0.action.isMillumin }.flatMap { mapper.messages(for: $0) }
        let millumin = commands.filter(\.action.isMillumin).flatMap { milluminMapper.messages(for: $0) }
        var error: String?
        func deliver(_ messages: [OSCMessage], via sender: OSCSender?, missing: String) {
            guard !messages.isEmpty else { return }
            guard let sender else { error = missing; return }
            for m in messages {
                do { try sender.send(m) } catch let e { error = e.localizedDescription }
            }
        }
        deliver(hog, via: sender, missing: "Console address not configured")
        deliver(millumin, via: milluminSender, missing: "Millumin address not configured")
        return (hog + millumin, error)
    }

    private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate {
        var onFinish: (() -> Void)?
        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            DispatchQueue.main.async { self.onFinish?() }
        }
    }

    private func tick() {
        guard let p = player, p.isPlaying else { return }
        let now = p.currentTime
        let due = runner.tick(time: now)
        guard autoFire, !due.isEmpty else { return }
        for trigger in due {
            let event = send(trigger: trigger, at: now)
            DispatchQueue.main.async { self.onFire?(event) }
        }
    }
}
#endif
