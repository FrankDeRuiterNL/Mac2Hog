import XCTest
@testable import Mac2HogCore

final class AnalyzerTests: XCTestCase {
    func testTempoSnaresAndBreak() {
        let song = SyntheticSong.make()
        let result = AudioAnalyzer().analyze(song.audio)

        XCTAssertEqual(result.bpm, 120, accuracy: 1.0, "tempo")

        // At least 85% of real snares detected within 40 ms.
        let found = song.snareTimes.filter { s in result.snares.contains { abs($0.time - s) < 0.04 } }
        XCTAssertGreaterThan(Double(found.count) / Double(song.snareTimes.count), 0.9, "snare recall")
        // Few false positives (hats/kicks should not be reported as snares).
        let falsePositives = result.snares.filter { h in !song.snareTimes.contains { abs($0 - h.time) < 0.04 } }
        XCTAssertLessThan(Double(falsePositives.count), Double(song.snareTimes.count) * 0.1, "snare precision")

        // Break detected around the drumless bars.
        XCTAssertTrue(result.breaks.contains { abs($0.start - song.breakRange.lowerBound) < 1.1 && abs($0.end - song.breakRange.upperBound) < 1.1 },
                      "break: \(result.breaks)")
        // Sections: a boundary near the break start.
        XCTAssertTrue(result.sections.contains { abs($0.start - song.breakRange.lowerBound) < 1.1 }, "sections: \(result.sections.map { ($0.name, $0.start) })")
        XCTAssertTrue(result.sections.contains { $0.kind == .breakdown })

        // Beat grid: downbeats line up with kick hits on 1.
        XCTAssertFalse(result.beats.isEmpty)
        let downbeats = result.downbeats.map(\.time).filter { $0 < song.breakRange.lowerBound - 0.5 }
        let barLength = 2.0
        let aligned = downbeats.filter { d in abs(d / barLength - (d / barLength).rounded()) * barLength < 0.05 }
        XCTAssertGreaterThan(Double(aligned.count) / Double(max(1, downbeats.count)), 0.8, "downbeat alignment \(downbeats.prefix(4))")
    }

    func testOtherTempo() {
        var layout = SyntheticSong.Layout()
        layout.bpm = 140
        let result = AudioAnalyzer().analyze(SyntheticSong.make(layout).audio)
        XCTAssertEqual(result.bpm, 140, accuracy: 1.5)
    }

    func testWAVRoundTripAndResample() throws {
        let tone = (0..<44_100).map { Float(sin(2 * Double.pi * 440 * Double($0) / 44_100)) * 0.5 }
        let data = WAVDecoder.encode16(samples: tone, sampleRate: 44_100)
        let decoded = try WAVDecoder.decode(data: data)
        XCTAssertEqual(decoded.sampleRate, 44_100)
        XCTAssertEqual(decoded.samples.count, tone.count)
        XCTAssertEqual(decoded.samples[100], tone[100], accuracy: 0.001)
        let r = decoded.resampled(to: 22_050)
        XCTAssertEqual(r.samples.count, 22_050, accuracy: 1)
        XCTAssertEqual(r.duration, 1, accuracy: 0.01)
    }

    func testFixedGrid() {
        var r = AnalysisResult(duration: 10, bpm: 120, tempoCandidates: [], beatsPerBar: 4, beats: [], snares: [], kicks: [],
                               sections: [], breaks: [], waveform: [], energy: [], energyRate: 1)
        r.applyFixedGrid(bpm: 120, firstDownbeat: 1.0)
        XCTAssertEqual(r.beats.first?.time ?? -1, 0.0, accuracy: 1e-9)
        XCTAssertEqual(r.beats.first { $0.time == 1.0 }?.beatInBar, 1)
        XCTAssertEqual(r.beats.first { $0.time == 1.0 }?.bar, 1)
        XCTAssertEqual(r.beats.count, 20)
    }
}
