import Foundation

public struct Beat: Codable, Hashable, Sendable {
    public var time: Double
    /// 1-based bar number.
    public var bar: Int
    /// 1-based position in the bar (1 = downbeat).
    public var beatInBar: Int
    public init(time: Double, bar: Int, beatInBar: Int) { self.time = time; self.bar = bar; self.beatInBar = beatInBar }
}

public struct Hit: Codable, Hashable, Sendable {
    public var time: Double
    /// Relative strength 0...1.
    public var strength: Double
    /// True when the hit falls on the beat grid (e.g. a backbeat snare).
    public var onGrid: Bool
    public init(time: Double, strength: Double, onGrid: Bool) { self.time = time; self.strength = strength; self.onGrid = onGrid }
}

public enum SectionKind: String, Codable, CaseIterable, Sendable {
    case intro, verse, buildUp, chorus, breakdown, bridge, outro, section

    public var displayName: String {
        switch self {
        case .intro: return "Intro"
        case .verse: return "Verse"
        case .buildUp: return "Build-up"
        case .chorus: return "Chorus / Drop"
        case .breakdown: return "Break"
        case .bridge: return "Bridge"
        case .outro: return "Outro"
        case .section: return "Section"
        }
    }
}

public struct SongSection: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var start: Double
    public var end: Double
    public var kind: SectionKind
    public var name: String
    /// Similarity group letter: sections sharing a letter sound alike (A, B, C …).
    public var group: String
    /// Relative loudness 0...1 compared to the loudest section.
    public var energy: Double

    public init(id: UUID = UUID(), start: Double, end: Double, kind: SectionKind, name: String, group: String, energy: Double) {
        self.id = id; self.start = start; self.end = end; self.kind = kind; self.name = name; self.group = group; self.energy = energy
    }

    public var duration: Double { end - start }
}

public struct BreakRegion: Codable, Hashable, Sendable {
    public var start: Double
    public var end: Double
    public init(start: Double, end: Double) { self.start = start; self.end = end }
    public var duration: Double { end - start }
}

public struct TempoCandidate: Codable, Hashable, Sendable {
    public var bpm: Double
    public var confidence: Double
}

/// Everything the analyzer learned about a song.
public struct AnalysisResult: Codable, Sendable {
    public var duration: Double
    public var bpm: Double
    public var tempoCandidates: [TempoCandidate]
    public var beatsPerBar: Int
    public var beats: [Beat]
    public var snares: [Hit]
    public var kicks: [Hit]
    public var sections: [SongSection]
    public var breaks: [BreakRegion]
    /// Peak amplitude overview (0...1) for drawing a waveform.
    public var waveform: [Float]
    /// Smoothed loudness curve (0...1) sampled at `energyRate` Hz.
    public var energy: [Float]
    public var energyRate: Double

    public init(duration: Double, bpm: Double, tempoCandidates: [TempoCandidate], beatsPerBar: Int, beats: [Beat],
                snares: [Hit], kicks: [Hit], sections: [SongSection], breaks: [BreakRegion],
                waveform: [Float], energy: [Float], energyRate: Double) {
        self.duration = duration; self.bpm = bpm; self.tempoCandidates = tempoCandidates; self.beatsPerBar = beatsPerBar
        self.beats = beats; self.snares = snares; self.kicks = kicks; self.sections = sections; self.breaks = breaks
        self.waveform = waveform; self.energy = energy; self.energyRate = energyRate
    }

    public var downbeats: [Beat] { beats.filter { $0.beatInBar == 1 } }

    /// Rebuilds a strictly constant beat grid from a (user corrected) BPM and first downbeat.
    public mutating func applyFixedGrid(bpm: Double, firstDownbeat: Double) {
        guard bpm > 0 else { return }
        self.bpm = bpm
        let period = 60 / bpm
        var t = firstDownbeat
        while t - period >= 0 { t -= period }
        let lead = Int(((firstDownbeat - t) / period).rounded())
        var out: [Beat] = []
        var i = 0
        while t < duration {
            let rel = i - lead
            let bar = Int(floor(Double(rel) / Double(beatsPerBar))) + 1
            let pos = ((rel % beatsPerBar) + beatsPerBar) % beatsPerBar + 1
            out.append(Beat(time: t, bar: bar, beatInBar: pos))
            t += period; i += 1
        }
        beats = out
    }
}
