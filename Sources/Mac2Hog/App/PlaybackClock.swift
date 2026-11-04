#if os(macOS)
import Foundation
import Combine

/// Song position and play state, updated ~30× per second while playing. Only views that display these
/// values observe this object, which keeps the rest of the UI idle during playback.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var isPlaying = false
    /// Wall clock for setlist countdowns (only ticks while a setlist is running).
    @Published var now = Date()
}
#endif
