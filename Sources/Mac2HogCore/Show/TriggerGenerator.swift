import Foundation

/// Turns analysis markers into show triggers.
public struct TriggerGenerator: Sendable {
    public enum SnareMode: String, Codable, CaseIterable, Sendable, Identifiable {
        case none, onGrid, strong, all
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .none: return "None"
            case .onGrid: return "On the beat grid only"
            case .strong: return "Strong hits only"
            case .all: return "All detected hits"
            }
        }
    }

    public var sectionStarts = true
    public var sectionEnds = false
    public var breaks = true
    public var snares: SnareMode = .none
    public var everyNBars = 0
    /// Command applied to every generated snare trigger (e.g. a flash cuelist).
    public var snareCommand: HogCommand?
    /// Only generate snare triggers inside these sections (empty = whole song).
    public var snareSectionIDs: Set<UUID> = []

    public init() {}

    public func generate(from analysis: AnalysisResult) -> [ShowTrigger] {
        var out: [ShowTrigger] = []
        if sectionStarts {
            out += analysis.sections.map { ShowTrigger(time: $0.start, name: $0.name, source: .sectionStart) }
        }
        if sectionEnds {
            out += analysis.sections.map { ShowTrigger(time: $0.end, name: "End \($0.name)", source: .sectionEnd) }
        }
        if breaks {
            for (i, b) in analysis.breaks.enumerated() {
                out.append(ShowTrigger(time: b.start, name: "Break \(i + 1) start", source: .breakStart))
                out.append(ShowTrigger(time: b.end, name: "Break \(i + 1) end", source: .breakEnd))
            }
        }
        let hits: [Hit]
        switch snares {
        case .none: hits = []
        case .onGrid: hits = analysis.snares.filter(\.onGrid)
        case .strong: hits = analysis.snares.filter { $0.strength >= 0.5 }
        case .all: hits = analysis.snares
        }
        let ranges = analysis.sections.filter { snareSectionIDs.contains($0.id) }.map { $0.start..<$0.end }
        for (i, h) in hits.enumerated() where ranges.isEmpty || ranges.contains(where: { $0.contains(h.time) }) {
            out.append(ShowTrigger(time: h.time, name: "Snare \(i + 1)", source: .snare,
                                   commands: snareCommand.map { [$0.withNewID()] } ?? []))
        }
        if everyNBars > 0 {
            for b in analysis.downbeats where b.bar >= 1 && (b.bar - 1) % everyNBars == 0 {
                out.append(ShowTrigger(time: b.time, name: "Bar \(b.bar)", source: .downbeat))
            }
        }
        // Remove near-duplicates (e.g. section start and break start at the same moment).
        out.sort { $0.time < $1.time }
        var deduped: [ShowTrigger] = []
        for t in out {
            if let last = deduped.last, abs(last.time - t.time) < 0.05, last.source != .snare, t.source != .snare { continue }
            deduped.append(t)
        }
        return deduped
    }

    /// Snaps a time to the nearest beat (or subdivision) of the analysis grid.
    public static func snap(_ time: Double, to analysis: AnalysisResult, subdivision: Int = 1) -> Double {
        let beats = analysis.beats.map(\.time)
        guard beats.count > 1 else { return time }
        var grid: [Double] = []
        for i in 0..<(beats.count - 1) {
            for s in 0..<max(1, subdivision) { grid.append(beats[i] + (beats[i + 1] - beats[i]) * Double(s) / Double(max(1, subdivision))) }
        }
        grid.append(beats.last!)
        return grid.min { abs($0 - time) < abs($1 - time) } ?? time
    }
}

extension HogCommand {
    public func withNewID() -> HogCommand {
        var c = self
        c.id = UUID()
        return c
    }
}
