import Foundation

/// Decides which triggers fire as the song plays (automatic timecode mode).
/// Seeking backwards or jumping forward resets the position without firing skipped triggers.
public struct ShowRunner: Sendable {
    public private(set) var triggers: [ShowTrigger]
    /// Fire triggers this many seconds early to compensate for network/console latency.
    public var latencyCompensation: Double
    /// A jump larger than this between ticks is treated as a seek.
    public var maxTickJump: Double = 0.5
    private var lastTime: Double?

    public init(triggers: [ShowTrigger], latencyCompensation: Double = 0) {
        self.triggers = triggers.filter(\.enabled).sorted { $0.time < $1.time }
        self.latencyCompensation = latencyCompensation
    }

    public mutating func update(triggers: [ShowTrigger]) {
        self.triggers = triggers.filter(\.enabled).sorted { $0.time < $1.time }
    }

    /// Positions the runner at `time`; triggers at exactly `time` will fire on the next tick.
    public mutating func seek(to time: Double) {
        lastTime = time - latencyCompensation - 1e-6
    }

    public mutating func reset() { lastTime = nil }

    /// Advances to `time` and returns the triggers crossed since the previous tick.
    public mutating func tick(time: Double) -> [ShowTrigger] {
        let now = time + latencyCompensation
        guard let last = lastTime else {
            lastTime = now
            // First tick from the start of the song fires anything at t <= now (e.g. a trigger at 0).
            return time < 0.25 ? triggers.filter { $0.time <= now } : []
        }
        if now < last || now - last > maxTickJump {
            lastTime = now
            return []
        }
        lastTime = now
        return triggers.filter { $0.time > last && $0.time <= now }
    }

    /// The next trigger after `time`, for countdown display.
    public func nextTrigger(after time: Double) -> ShowTrigger? {
        triggers.first { $0.time > time + latencyCompensation }
    }
}

/// Manual "cue stack" mode: each GO (spacebar) fires the next trigger in time order.
public struct CueStack: Sendable {
    public private(set) var cues: [ShowTrigger]
    /// Index of the cue that fires on the next GO.
    public private(set) var nextIndex: Int = 0

    public init(triggers: [ShowTrigger]) {
        cues = triggers.filter(\.enabled).sorted { $0.time < $1.time }
    }

    public var current: ShowTrigger? { nextIndex > 0 && nextIndex - 1 < cues.count ? cues[nextIndex - 1] : nil }
    public var next: ShowTrigger? { nextIndex < cues.count ? cues[nextIndex] : nil }
    public var isFinished: Bool { nextIndex >= cues.count }

    public mutating func go() -> ShowTrigger? {
        guard nextIndex < cues.count else { return nil }
        defer { nextIndex += 1 }
        return cues[nextIndex]
    }

    /// Steps back one cue and returns the cue that is now "current" (to re-fire it).
    public mutating func back() -> ShowTrigger? {
        guard nextIndex > 0 else { return nil }
        nextIndex -= 1
        return current
    }

    public mutating func select(index: Int) { nextIndex = max(0, min(cues.count, index)) }

    public mutating func select(id: UUID) {
        if let i = cues.firstIndex(where: { $0.id == id }) { nextIndex = i }
    }

    public mutating func reset() { nextIndex = 0 }
}
