import Foundation

public enum TriggerSource: String, Codable, CaseIterable, Sendable {
    case manual, snare, kick, beat, downbeat, sectionStart, sectionEnd, breakStart, breakEnd

    public var displayName: String {
        switch self {
        case .manual: return "Manual"
        case .snare: return "Snare"
        case .kick: return "Kick"
        case .beat: return "Beat"
        case .downbeat: return "Bar"
        case .sectionStart: return "Section start"
        case .sectionEnd: return "Section end"
        case .breakStart: return "Break start"
        case .breakEnd: return "Break end"
        }
    }
}

/// How a cue is started.
public enum CueStartMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Fires at its own timecode position in the song.
    case timecode
    /// Fires `delay` seconds after the previous cue *started*.
    case follow
    /// Fires `delay` seconds after the previous cue *finished* (its start + its duration).
    case wait

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .timecode: return "Timecode"
        case .follow: return "Follow"
        case .wait: return "Wait"
        }
    }
}

/// A point on the song timeline that fires one or more console commands.
public struct ShowTrigger: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// Song position in seconds. For Follow / Wait cues this is computed from the previous cue.
    public var time: Double
    public var name: String
    public var source: TriggerSource
    public var commands: [HogCommand]
    public var enabled: Bool
    public var notes: String
    public var startMode: CueStartMode
    /// Seconds added after the previous cue's start (Follow) or end (Wait).
    public var delay: Double
    /// How long this cue lasts (e.g. its fade time on the console). Used by a following Wait cue.
    public var duration: Double

    public init(id: UUID = UUID(), time: Double, name: String, source: TriggerSource = .manual,
                commands: [HogCommand] = [], enabled: Bool = true, notes: String = "",
                startMode: CueStartMode = .timecode, delay: Double = 0, duration: Double = 0) {
        self.id = id; self.time = time; self.name = name; self.source = source
        self.commands = commands; self.enabled = enabled; self.notes = notes
        self.startMode = startMode; self.delay = delay; self.duration = duration
    }

    /// "Timecode", "Follow +5s", "Wait +10s".
    public var startDescription: String {
        switch startMode {
        case .timecode: return "Timecode"
        case .follow, .wait: return "\(startMode.displayName) +\(Self.formatSeconds(delay))s"
        }
    }

    static func formatSeconds(_ s: Double) -> String {
        s == s.rounded() ? String(Int(s)) : String(format: "%.1f", s)
    }

    private enum CodingKeys: String, CodingKey {
        case id, time, name, source, commands, enabled, notes, startMode, delay, duration
    }

    // Tolerant decoding so shows saved by earlier versions still open.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        time = try c.decodeIfPresent(Double.self, forKey: .time) ?? 0
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        source = (try? c.decodeIfPresent(TriggerSource.self, forKey: .source)) ?? .manual
        commands = try c.decodeIfPresent([HogCommand].self, forKey: .commands) ?? []
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        startMode = (try? c.decodeIfPresent(CueStartMode.self, forKey: .startMode)) ?? .timecode
        delay = try c.decodeIfPresent(Double.self, forKey: .delay) ?? 0
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
    }
}

/// Cue ordering and Follow / Wait timing.
///
/// The cue list order is the array order. A Timecode cue together with the Follow / Wait cues
/// directly after it forms a block; blocks are kept sorted by their Timecode cue so chains stay intact.
public enum CueTiming {
    /// Start time of `cue` given the previous cue in the list (nil = start of song / state).
    public static func startTime(of cue: ShowTrigger, after previous: ShowTrigger?) -> Double {
        switch cue.startMode {
        case .timecode: return cue.time
        case .follow: return (previous?.time ?? 0) + cue.delay
        case .wait: return (previous.map { $0.time + $0.duration } ?? 0) + cue.delay
        }
    }

    /// Delay from `previous` starting until `cue` starts.
    public static func offset(of cue: ShowTrigger, after previous: ShowTrigger) -> Double {
        switch cue.startMode {
        case .timecode: return max(0, cue.time - previous.time)
        case .follow: return cue.delay
        case .wait: return previous.duration + cue.delay
        }
    }

    /// Writes the computed start time into every Follow / Wait cue (array order is cue order).
    public static func resolve(_ cues: inout [ShowTrigger]) {
        var previous: ShowTrigger?
        for i in cues.indices {
            if cues[i].startMode != .timecode {
                cues[i].time = max(0, startTime(of: cues[i], after: previous))
            }
            previous = cues[i]
        }
    }

    /// Sorts blocks (a Timecode cue + its Follow/Wait chain) by time, then resolves chained times.
    public static func normalize(_ cues: inout [ShowTrigger]) {
        var blocks: [[ShowTrigger]] = []
        for cue in cues {
            if cue.startMode == .timecode || blocks.isEmpty { blocks.append([cue]) } else { blocks[blocks.count - 1].append(cue) }
        }
        // Stable sort by head time; a leading chain without a timecode head stays first.
        let indexed = blocks.enumerated().map { (offset: $0.offset, block: $0.element) }
        let sorted = indexed.sorted { a, b in
            let ta = a.block[0].startMode == .timecode ? a.block[0].time : -1
            let tb = b.block[0].startMode == .timecode ? b.block[0].time : -1
            return ta != tb ? ta < tb : a.offset < b.offset
        }
        cues = sorted.flatMap(\.block)
        resolve(&cues)
    }

    /// Total running time of a cue sequence (last cue start + its duration).
    public static func length(of cues: [ShowTrigger]) -> Double {
        cues.filter(\.enabled).map { $0.time + $0.duration }.max() ?? 0
    }
}

/// A song + its analysis + the triggers that make up the light show. Saved as `.mac2hog` (JSON).
public struct ShowProject: Codable, Sendable {
    public static let fileExtension = "mac2hog"

    public var version: Int = 1
    public var name: String
    public var songPath: String?
    public var analysis: AnalysisResult?
    public var timecodeRate: TimecodeRate
    /// Timecode at song position 0 (commonly 01:00:00:00).
    public var timecodeStart: Timecode
    public var triggers: [ShowTrigger]
    public var show: HogShow?

    public init(name: String = "Untitled", songPath: String? = nil, analysis: AnalysisResult? = nil,
                timecodeRate: TimecodeRate = .fps25, timecodeStart: Timecode? = nil,
                triggers: [ShowTrigger] = [], show: HogShow? = nil) {
        self.name = name
        self.songPath = songPath
        self.analysis = analysis
        self.timecodeRate = timecodeRate
        self.timecodeStart = timecodeStart ?? Timecode(hours: 1, rate: timecodeRate)
        self.triggers = triggers
        self.show = show
    }

    /// Cues in cue-list order (Timecode blocks sorted, Follow / Wait chains kept behind their cue).
    public var sortedTriggers: [ShowTrigger] {
        var t = triggers
        CueTiming.normalize(&t)
        return t
    }

    /// Re-sorts the cue list and recomputes Follow / Wait times. Call after edits.
    public mutating func normalizeCues() { CueTiming.normalize(&triggers) }

    public func timecode(at songTime: Double) -> Timecode {
        Timecode(seconds: timecodeStart.timeInSeconds + songTime, rate: timecodeRate)
    }

    public func songTime(for timecode: Timecode) -> Double {
        timecode.timeInSeconds - timecodeStart.timeInSeconds
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }

    public static func decode(_ data: Data) throws -> ShowProject {
        try JSONDecoder().decode(ShowProject.self, from: data)
    }

    /// Exports the cue sheet as CSV (timecode, song time, name, commands, OSC).
    public func cueSheetCSV(mapper: HogOSCMapper) -> String {
        var lines = ["#,Timecode,Time (s),Start,Name,Source,Commands,OSC"]
        for (i, t) in sortedTriggers.enumerated() {
            let cmds = t.commands.map(\.summary).joined(separator: " | ")
            let osc = t.commands.flatMap { mapper.messages(for: $0) }.map(\.description).joined(separator: " | ")
            func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            lines.append("\(i + 1),\(timecode(at: t.time)),\(String(format: "%.3f", t.time)),\(t.startDescription),\(q(t.name)),\(t.source.displayName),\(q(cmds)),\(q(osc))")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
