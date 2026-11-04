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

/// A point on the song timeline that fires one or more console commands.
public struct ShowTrigger: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var time: Double
    public var name: String
    public var source: TriggerSource
    public var commands: [HogCommand]
    public var enabled: Bool
    public var notes: String

    public init(id: UUID = UUID(), time: Double, name: String, source: TriggerSource = .manual,
                commands: [HogCommand] = [], enabled: Bool = true, notes: String = "") {
        self.id = id; self.time = time; self.name = name; self.source = source
        self.commands = commands; self.enabled = enabled; self.notes = notes
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

    public var sortedTriggers: [ShowTrigger] { triggers.sorted { $0.time < $1.time } }

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
        var lines = ["#,Timecode,Time (s),Name,Source,Commands,OSC"]
        for (i, t) in sortedTriggers.enumerated() {
            let cmds = t.commands.map(\.summary).joined(separator: " | ")
            let osc = t.commands.flatMap { mapper.messages(for: $0) }.map(\.description).joined(separator: " | ")
            func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            lines.append("\(i + 1),\(timecode(at: t.time)),\(String(format: "%.3f", t.time)),\(q(t.name)),\(t.source.displayName),\(q(cmds)),\(q(osc))")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
