import Foundation

/// Persisted application settings (network, OSC, timecode, analysis, libraries).
public struct AppSettings: Codable, Hashable, Sendable {
    // Network
    public var consoleHost: String = "192.168.0.10"
    /// Hog 4 "OSC In" port (Setup → Network → OSC on the console).
    public var consolePort: UInt16 = 7001
    /// Optional port to receive the Hog's "OSC Out" status feedback.
    public var feedbackEnabled: Bool = false
    public var feedbackPort: UInt16 = 7002

    // OSC
    public var osc = HogOSCConfiguration()
    /// Milliseconds to fire triggers early to compensate network/console latency.
    public var latencyCompensationMs: Double = 0
    /// Commands sent when the show is stopped (e.g. release all).
    public var sendReleaseOnStop: Bool = false

    // Timecode
    public var timecodeRate: TimecodeRate = .fps25
    public var timecodeStartHour: Int = 1
    /// Play LTC on the right channel (song on the left) so the Hog can chase timecode.
    public var ltcOnRightChannel: Bool = false

    // Analysis
    public var minBPM: Double = 70
    public var maxBPM: Double = 180
    public var snareSensitivity: Double = 0.5
    public var minSectionBars: Int = 4

    // Libraries
    public var recentSongs: [String] = []
    public var recentShowfiles: [String] = []
    public var selectedShowfile: String?

    // Predefined triggers (reusable command sets)
    public var predefinedTriggers: [PredefinedTrigger] = []

    /// Recently opened setlists (.mac2hogset), shows (.mac2hog) and single songs, newest first.
    public var recentProjects: [String] = []

    // Hardware
    /// Core Audio device UID for the song; nil = system default output.
    public var mainAudioDeviceUID: String?
    /// Core Audio device UID for the generated LTC timecode; nil = no LTC output.
    public var ltcAudioDeviceUID: String?
    public var ltcChannel: LTCChannel = .both
    /// BSD name of the network adapter for OSC (e.g. "en0"); nil = automatic (system routing).
    public var networkInterface: String?

    public init() {}

    public var analyzerOptions: AudioAnalyzer.Options {
        var o = AudioAnalyzer.Options()
        o.minBPM = minBPM
        o.maxBPM = maxBPM
        o.preferredBPM = min(max(120, minBPM), maxBPM)
        o.snareSensitivity = snareSensitivity
        o.minSectionBars = minSectionBars
        return o
    }

    public mutating func remember(song path: String) {
        recentSongs.removeAll { $0 == path }
        recentSongs.insert(path, at: 0)
        recentSongs = Array(recentSongs.prefix(20))
    }

    public mutating func remember(project path: String) {
        recentProjects.removeAll { $0 == path }
        recentProjects.insert(path, at: 0)
        recentProjects = Array(recentProjects.prefix(12))
    }

    public mutating func remember(showfile path: String) {
        recentShowfiles.removeAll { $0 == path }
        recentShowfiles.insert(path, at: 0)
        recentShowfiles = Array(recentShowfiles.prefix(20))
    }

    // Tolerant decoding so new settings never wipe a user's saved configuration.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        consoleHost = (try? c.decode(String.self, forKey: .consoleHost)) ?? d.consoleHost
        consolePort = (try? c.decode(UInt16.self, forKey: .consolePort)) ?? d.consolePort
        feedbackEnabled = (try? c.decode(Bool.self, forKey: .feedbackEnabled)) ?? d.feedbackEnabled
        feedbackPort = (try? c.decode(UInt16.self, forKey: .feedbackPort)) ?? d.feedbackPort
        osc = (try? c.decode(HogOSCConfiguration.self, forKey: .osc)) ?? d.osc
        latencyCompensationMs = (try? c.decode(Double.self, forKey: .latencyCompensationMs)) ?? d.latencyCompensationMs
        sendReleaseOnStop = (try? c.decode(Bool.self, forKey: .sendReleaseOnStop)) ?? d.sendReleaseOnStop
        timecodeRate = (try? c.decode(TimecodeRate.self, forKey: .timecodeRate)) ?? d.timecodeRate
        timecodeStartHour = (try? c.decode(Int.self, forKey: .timecodeStartHour)) ?? d.timecodeStartHour
        ltcOnRightChannel = (try? c.decode(Bool.self, forKey: .ltcOnRightChannel)) ?? d.ltcOnRightChannel
        minBPM = (try? c.decode(Double.self, forKey: .minBPM)) ?? d.minBPM
        maxBPM = (try? c.decode(Double.self, forKey: .maxBPM)) ?? d.maxBPM
        snareSensitivity = (try? c.decode(Double.self, forKey: .snareSensitivity)) ?? d.snareSensitivity
        minSectionBars = (try? c.decode(Int.self, forKey: .minSectionBars)) ?? d.minSectionBars
        recentSongs = (try? c.decode([String].self, forKey: .recentSongs)) ?? d.recentSongs
        recentShowfiles = (try? c.decode([String].self, forKey: .recentShowfiles)) ?? d.recentShowfiles
        selectedShowfile = try? c.decode(String.self, forKey: .selectedShowfile)
        predefinedTriggers = (try? c.decode([PredefinedTrigger].self, forKey: .predefinedTriggers)) ?? d.predefinedTriggers
        // Older settings had only recent songs: start the project list from those.
        recentProjects = (try? c.decode([String].self, forKey: .recentProjects)) ?? Array(recentSongs.prefix(12))
        mainAudioDeviceUID = try? c.decode(String.self, forKey: .mainAudioDeviceUID)
        ltcAudioDeviceUID = try? c.decode(String.self, forKey: .ltcAudioDeviceUID)
        ltcChannel = (try? c.decode(LTCChannel.self, forKey: .ltcChannel)) ?? d.ltcChannel
        networkInterface = try? c.decode(String.self, forKey: .networkInterface)
    }
}

/// Which channel(s) of the LTC output device carry the timecode.
public enum LTCChannel: String, Codable, CaseIterable, Sendable, Identifiable {
    case both, left, right
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .both: return "Left + Right"
        case .left: return "Left (channel 1)"
        case .right: return "Right (channel 2)"
        }
    }

    /// Interleaved stereo with the LTC signal on the selected channel(s).
    public func stereo(_ ltc: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: ltc.count * 2)
        for i in 0..<ltc.count {
            if self != .right { out[2 * i] = ltc[i] }
            if self != .left { out[2 * i + 1] = ltc[i] }
        }
        return out
    }
}
