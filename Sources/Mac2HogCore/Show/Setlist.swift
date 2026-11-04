import Foundation

/// One song in a setlist: a complete show project plus the pause that follows it.
public struct SetlistSong: Codable, Identifiable, Sendable {
    public var id: UUID
    public var project: ShowProject
    /// Seconds between the end of this song and the start of the next (nil = setlist default).
    public var gapAfter: Double?

    public init(id: UUID = UUID(), project: ShowProject, gapAfter: Double? = nil) {
        self.id = id; self.project = project; self.gapAfter = gapAfter
    }

    public var name: String { project.name }
}

/// The three lighting "states" around the songs of a setlist.
public enum SetlistState: String, Codable, CaseIterable, Sendable, Identifiable {
    case starting, waiting, ending
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .starting: return "Starting state"
        case .waiting: return "Waiting state"
        case .ending: return "Ending state"
        }
    }
    public var explanation: String {
        switch self {
        case .starting: return "Fires when the setlist starts, before the first song."
        case .waiting: return "Fires in the pause between two songs."
        case .ending: return "Fires after the last song has finished."
        }
    }
}

/// A sequence of songs that follow each other, with Starting / Waiting / Ending light states.
/// Saved as `.mac2hogset` (JSON with the song projects embedded).
public struct Setlist: Codable, Sendable {
    public static let fileExtension = "mac2hogset"

    public var version: Int = 1
    public var name: String
    public var songs: [SetlistSong]
    /// Default pause between songs in seconds.
    public var defaultGap: Double
    /// Seconds from setlist start until the first song starts (the Starting state plays meanwhile).
    public var startDelay: Double
    /// Start the next song automatically after the pause.
    public var autoAdvance: Bool
    /// State cue lists. Cue times are seconds from the moment the state begins.
    public var startingState: [ShowTrigger]
    public var waitingState: [ShowTrigger]
    public var endingState: [ShowTrigger]

    public init(name: String = "New Setlist", songs: [SetlistSong] = [], defaultGap: Double = 10,
                startDelay: Double = 5, autoAdvance: Bool = true) {
        self.name = name; self.songs = songs; self.defaultGap = defaultGap; self.startDelay = startDelay
        self.autoAdvance = autoAdvance
        startingState = []; waitingState = []; endingState = []
    }

    public func cues(for state: SetlistState) -> [ShowTrigger] {
        switch state {
        case .starting: return startingState
        case .waiting: return waitingState
        case .ending: return endingState
        }
    }

    public mutating func setCues(_ cues: [ShowTrigger], for state: SetlistState) {
        switch state {
        case .starting: startingState = cues
        case .waiting: waitingState = cues
        case .ending: endingState = cues
        }
    }

    public func gap(after index: Int) -> Double {
        guard songs.indices.contains(index) else { return defaultGap }
        return songs[index].gapAfter ?? defaultGap
    }

    /// Total running time including pauses (songs without analysis count as 0).
    public var totalDuration: Double {
        let songTime = songs.map { $0.project.analysis?.duration ?? 0 }.reduce(0, +)
        let gaps = songs.indices.dropLast().map { gap(after: $0) }.reduce(0, +)
        return startDelay + songTime + gaps
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }

    public static func decode(_ data: Data) throws -> Setlist {
        try JSONDecoder().decode(Setlist.self, from: data)
    }

    private enum CodingKeys: String, CodingKey {
        case version, name, songs, defaultGap, startDelay, autoAdvance, startingState, waitingState, endingState
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Setlist"
        songs = try c.decodeIfPresent([SetlistSong].self, forKey: .songs) ?? []
        defaultGap = try c.decodeIfPresent(Double.self, forKey: .defaultGap) ?? 10
        startDelay = try c.decodeIfPresent(Double.self, forKey: .startDelay) ?? 5
        autoAdvance = try c.decodeIfPresent(Bool.self, forKey: .autoAdvance) ?? true
        startingState = try c.decodeIfPresent([ShowTrigger].self, forKey: .startingState) ?? []
        waitingState = try c.decodeIfPresent([ShowTrigger].self, forKey: .waitingState) ?? []
        endingState = try c.decodeIfPresent([ShowTrigger].self, forKey: .endingState) ?? []
    }
}

/// A reusable, named set of console commands (Settings › Predefined) that can be added to any cue.
public struct PredefinedTrigger: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var commands: [HogCommand]

    public init(id: UUID = UUID(), name: String, commands: [HogCommand] = []) {
        self.id = id; self.name = name; self.commands = commands
    }

    /// Fresh copies (new IDs) of the commands, ready to attach to a cue.
    public func instantiate() -> [HogCommand] {
        commands.map { c in
            var copy = c.withNewID()
            if copy.label.isEmpty { copy.label = name }
            return copy
        }
    }
}
