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
    }

    private let queue = DispatchQueue(label: "mac2hog.engine", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var player: AVAudioPlayer?
    private var runner = ShowRunner(triggers: [])
    private var sender: OSCSender?
    private var mapper = HogOSCMapper()
    private var autoFire = true

    /// Delivered on the main queue.
    var onFire: ((FireEvent) -> Void)?

    init() {
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .microseconds(500))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    deinit { timer?.cancel() }

    // MARK: Configuration

    func configure(host: String, port: UInt16, mapper: HogOSCMapper, latency: Double) throws {
        let newSender = try OSCSender(host: host, port: port)
        queue.sync {
            self.sender = newSender
            self.mapper = mapper
            self.runner.latencyCompensation = latency
        }
    }

    func setTriggers(_ triggers: [ShowTrigger]) {
        queue.async { self.runner.update(triggers: triggers) }
    }

    func setAutoFire(_ enabled: Bool) {
        queue.async { self.autoFire = enabled }
    }

    // MARK: Transport (call from main)

    func load(player: AVAudioPlayer?) {
        queue.sync {
            self.player?.stop()
            self.player = player
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
        p.play()
    }

    func pause() { player?.pause() }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        queue.sync { runner.seek(to: 0) }
    }

    func seek(to time: Double) {
        guard let p = player else { return }
        let t = max(0, min(time, p.duration))
        p.currentTime = t
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

    private func send(trigger: ShowTrigger, at time: Double) -> FireEvent {
        let messages = trigger.commands.flatMap { mapper.messages(for: $0) }
        var error: String?
        if let s = sender {
            for m in messages {
                do { try s.send(m) } catch let e { error = e.localizedDescription }
            }
        } else if !messages.isEmpty {
            error = "Console address not configured"
        }
        return FireEvent(trigger: trigger, messages: messages, error: error, songTime: time)
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
