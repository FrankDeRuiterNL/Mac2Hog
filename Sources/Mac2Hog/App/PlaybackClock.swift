#if os(macOS)
import Foundation
import Combine

/// Song position and play state, updated ~30× per second while playing. Only views that display these
/// values observe this object, which keeps the rest of the UI idle during playback.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var currentTime: Double = 0 {
        didSet { anchorDate = Date() }
    }
    @Published var isPlaying = false
    /// When `currentTime` was last read from the player; used to interpolate the playhead smoothly.
    private(set) var anchorDate = Date()

    /// Song position right now, extrapolated between the 30 Hz updates while playing.
    func time(at date: Date) -> Double {
        isPlaying ? currentTime + max(0, min(0.25, date.timeIntervalSince(anchorDate))) : currentTime
    }
    /// Wall clock for setlist countdowns (only ticks while a setlist is running).
    @Published var now = Date()
}
#endif

#if os(macOS)
/// Per-fire state (last fired / running / inspector focus). Kept out of AppState so firing a cue
/// only redraws the cue list and inspector, not the whole window — which used to stall the playhead.
@MainActor
final class CueActivity: ObservableObject {
    @Published var lastFiredID: UUID?
    /// Fired cues whose Duration hasn't elapsed yet.
    @Published var runningCueIDs: Set<UUID> = []
    /// The cue shown in the inspector: the user's selection, or (with Follow on) the last fired cue.
    @Published var focusedCueID: UUID?
}

/// The OSC output log, kept separate for the same reason.
@MainActor
final class OSCLogStore: ObservableObject {
    @Published private(set) var entries: [OSCLogEntry] = []

    func append(_ entry: OSCLogEntry) {
        entries.append(entry)
        if entries.count > 500 { entries.removeFirst(entries.count - 500) }
    }

    func clear() { entries.removeAll() }
}
#endif
