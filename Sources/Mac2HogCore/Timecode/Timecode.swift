import Foundation

public enum TimecodeRate: String, Codable, CaseIterable, Sendable, Identifiable {
    case fps24 = "24"
    case fps25 = "25"
    case fps2997df = "29.97df"
    case fps30 = "30"

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .fps24: return "24 fps (Film)"
        case .fps25: return "25 fps (EBU)"
        case .fps2997df: return "29.97 fps drop-frame"
        case .fps30: return "30 fps (SMPTE)"
        }
    }
    /// Real frames per second.
    public var fps: Double {
        switch self {
        case .fps24: return 24
        case .fps25: return 25
        case .fps2997df: return 30_000.0 / 1001.0
        case .fps30: return 30
        }
    }
    /// Nominal (counted) frames per second.
    public var nominal: Int { self == .fps24 ? 24 : (self == .fps25 ? 25 : 30) }
    public var isDropFrame: Bool { self == .fps2997df }
}

/// SMPTE timecode value.
public struct Timecode: Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public var hours: Int
    public var minutes: Int
    public var seconds: Int
    public var frames: Int
    public var rate: TimecodeRate

    public init(hours: Int = 0, minutes: Int = 0, seconds: Int = 0, frames: Int = 0, rate: TimecodeRate = .fps25) {
        self.hours = hours; self.minutes = minutes; self.seconds = seconds; self.frames = frames; self.rate = rate
    }

    /// Parses "HH:MM:SS:FF" (or with ';' before frames for drop-frame).
    public init?(string: String, rate: TimecodeRate) {
        let parts = string.split(whereSeparator: { $0 == ":" || $0 == ";" || $0 == "." }).compactMap { Int($0) }
        guard parts.count == 4, parts[1] < 60, parts[2] < 60, parts[3] < rate.nominal else { return nil }
        self.init(hours: parts[0], minutes: parts[1], seconds: parts[2], frames: parts[3], rate: rate)
    }

    /// Counted frame number since 00:00:00:00 (accounting for drop-frame numbering).
    public var frameNumber: Int {
        let fps = rate.nominal
        let totalMinutes = hours * 60 + minutes
        var n = ((totalMinutes * 60) + seconds) * fps + frames
        if rate.isDropFrame { n -= 2 * (totalMinutes - totalMinutes / 10) }
        return n
    }

    public init(frameNumber: Int, rate: TimecodeRate) {
        var n = max(0, frameNumber)
        let fps = rate.nominal
        if rate.isDropFrame {
            // Re-insert dropped frame numbers (2 per minute, except every 10th minute).
            let perTen = 17_982, perMinute = 1798
            let tens = n / perTen
            let rem = n % perTen
            n += 18 * tens + (rem > 1 ? 2 * ((rem - 2) / perMinute) : 0)
        }
        let f = n % fps
        let totalSeconds = n / fps
        self.init(hours: (totalSeconds / 3600) % 24, minutes: (totalSeconds / 60) % 60, seconds: totalSeconds % 60, frames: f, rate: rate)
    }

    public init(seconds: Double, rate: TimecodeRate) {
        self.init(frameNumber: Int((max(0, seconds) * rate.fps + 1e-6).rounded(.down)), rate: rate)
    }

    /// Wall-clock seconds represented by this timecode.
    public var timeInSeconds: Double { Double(frameNumber) / rate.fps }

    public func adding(seconds: Double) -> Timecode {
        Timecode(seconds: timeInSeconds + seconds, rate: rate)
    }

    public var description: String {
        let sep = rate.isDropFrame ? ";" : ":"
        return String(format: "%02d:%02d:%02d%@%02d", hours, minutes, seconds, sep, frames)
    }

    public static func < (lhs: Timecode, rhs: Timecode) -> Bool { lhs.frameNumber < rhs.frameNumber }
}
