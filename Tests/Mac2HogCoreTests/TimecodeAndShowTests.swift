import XCTest
@testable import Mac2HogCore

final class TimecodeAndShowTests: XCTestCase {
    func testTimecodeConversions() {
        let tc = Timecode(seconds: 3600 + 61.5, rate: .fps25)
        XCTAssertEqual(tc.description, "01:01:01:12")
        XCTAssertEqual(Timecode(string: "01:01:01:12", rate: .fps25), tc)
        XCTAssertEqual(Timecode(hours: 1, rate: .fps30).adding(seconds: 2).description, "01:00:02:00")
    }

    func testDropFrame() {
        // 00:00:59;29 → next frame is 00:01:00;02 in drop-frame.
        let a = Timecode(hours: 0, minutes: 0, seconds: 59, frames: 29, rate: .fps2997df)
        let b = Timecode(frameNumber: a.frameNumber + 1, rate: .fps2997df)
        XCTAssertEqual(b.description, "00:01:00;02")
        // Minute 10 does not drop.
        let c = Timecode(hours: 0, minutes: 9, seconds: 59, frames: 29, rate: .fps2997df)
        XCTAssertEqual(Timecode(frameNumber: c.frameNumber + 1, rate: .fps2997df).description, "00:10:00;00")
        // Round trip across an hour.
        for n in stride(from: 0, to: 120_000, by: 997) {
            XCTAssertEqual(Timecode(frameNumber: n, rate: .fps2997df).frameNumber, n)
        }
    }

    func testLTCRoundTrip() {
        for rate in [TimecodeRate.fps24, .fps25, .fps30] {
            let start = Timecode(hours: 1, minutes: 2, seconds: 3, frames: 4, rate: rate)
            let audio = LTCEncoder.render(start: start, duration: 0.5, sampleRate: 48_000)
            let decoded = LTCEncoder.decode(audio, sampleRate: 48_000, rate: rate)
            XCTAssertGreaterThan(decoded.count, 5)
            // The first full frame may be partially lost; check continuity.
            XCTAssertTrue(decoded.contains(start.adding(seconds: 1 / rate.fps * 2)) || decoded.contains(start), "\(rate) \(decoded.prefix(3))")
            for w in zip(decoded, decoded.dropFirst()) { XCTAssertEqual(w.1.frameNumber - w.0.frameNumber, 1) }
            let bits = LTCEncoder.bits(for: start)
            XCTAssertEqual(bits.filter { $0 == 0 }.count % 2, 0)
        }
    }

    func testShowRunnerFiresInOrderAndHandlesSeek() {
        let triggers = [ShowTrigger(time: 0, name: "start"), ShowTrigger(time: 1, name: "a"),
                        ShowTrigger(time: 1.2, name: "b"), ShowTrigger(time: 5, name: "c"),
                        ShowTrigger(time: 6, name: "disabled", enabled: false)]
        var runner = ShowRunner(triggers: triggers)
        XCTAssertEqual(runner.tick(time: 0).map(\.name), ["start"])
        XCTAssertEqual(runner.tick(time: 0.5).map(\.name), [])
        XCTAssertEqual(runner.tick(time: 0.9).map(\.name), [])
        XCTAssertEqual(runner.tick(time: 1.25).map(\.name), ["a", "b"])
        // Seek forward past "c": nothing fires.
        XCTAssertEqual(runner.tick(time: 5.5).map(\.name), [])
        XCTAssertEqual(runner.tick(time: 6.2).map(\.name), [])
        // Seek back and replay.
        runner.seek(to: 4.9)
        XCTAssertEqual(runner.tick(time: 5.01).map(\.name), ["c"])
        // Latency compensation fires early.
        var early = ShowRunner(triggers: triggers, latencyCompensation: 0.1)
        early.seek(to: 0.8)
        XCTAssertEqual(early.tick(time: 0.95).map(\.name), ["a"])
    }

    func testCueStack() {
        var stack = CueStack(triggers: [ShowTrigger(time: 2, name: "b"), ShowTrigger(time: 1, name: "a")])
        XCTAssertEqual(stack.next?.name, "a")
        XCTAssertEqual(stack.go()?.name, "a")
        XCTAssertEqual(stack.go()?.name, "b")
        XCTAssertNil(stack.go())
        XCTAssertTrue(stack.isFinished)
        XCTAssertEqual(stack.back()?.name, "a")
        XCTAssertEqual(stack.next?.name, "b")
    }

    func testProjectRoundTripAndCSV() throws {
        var project = ShowProject(name: "Test")
        project.triggers = [ShowTrigger(time: 2, name: "Chorus", source: .sectionStart, commands: [.go(.cuelist, "1", label: "Wash")])]
        let decoded = try ShowProject.decode(project.encoded())
        XCTAssertEqual(decoded.triggers, project.triggers)
        XCTAssertEqual(decoded.timecode(at: 2).description, "01:00:02:00")
        let csv = project.cueSheetCSV(mapper: HogOSCMapper())
        XCTAssertTrue(csv.contains("/hog/playback/go/0 1"), csv)
    }

    func testGenerator() {
        var r = AnalysisResult(duration: 20, bpm: 120, tempoCandidates: [], beatsPerBar: 4, beats: [],
                               snares: [Hit(time: 1, strength: 1, onGrid: true), Hit(time: 1.3, strength: 0.2, onGrid: false)], kicks: [],
                               sections: [SongSection(start: 0, end: 8, kind: .intro, name: "Intro", group: "A", energy: 0.4),
                                          SongSection(start: 8, end: 20, kind: .chorus, name: "Chorus", group: "B", energy: 1)],
                               breaks: [BreakRegion(start: 8, end: 10)], waveform: [], energy: [], energyRate: 1)
        r.applyFixedGrid(bpm: 120, firstDownbeat: 0)
        var g = TriggerGenerator()
        g.snares = .onGrid
        g.snareCommand = .go(.cuelist, "9")
        let t = g.generate(from: r)
        XCTAssertEqual(t.map(\.name), ["Intro", "Snare 1", "Chorus", "Break 1 end"])
        XCTAssertEqual(t[1].commands.first?.objectNumber, "9")
        XCTAssertEqual(TriggerGenerator.snap(1.1, to: r), 1.0, accuracy: 1e-9)
    }

    func testSettingsDecodeTolerant() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data("{\"consoleHost\":\"10.0.0.5\"}".utf8))
        XCTAssertEqual(s.consoleHost, "10.0.0.5")
        XCTAssertEqual(s.consolePort, 7001)
    }
}
