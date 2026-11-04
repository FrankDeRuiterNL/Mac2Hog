import Foundation
@testable import Mac2HogCore

/// Builds a test song: drums (kick on 1 & 3, snare on 2 & 4, eighth hats) with a pad,
/// a drumless quiet break in the middle, then full drums again.
enum SyntheticSong {
    struct Layout {
        var bpm: Double = 120
        var introBars = 8
        var breakBars = 4
        var outroBars = 8
        var sampleRate: Double = 44_100
    }

    static func make(_ layout: Layout = Layout()) -> (audio: MonoAudio, snareTimes: [Double], breakRange: ClosedRange<Double>) {
        let beat = 60 / layout.bpm
        let bars = layout.introBars + layout.breakBars + layout.outroBars
        let total = Double(bars * 4) * beat + 1
        let sr = layout.sampleRate
        var x = [Float](repeating: 0, count: Int(total * sr))
        var rng = SeededGenerator(seed: 42)
        var snares: [Double] = []
        let breakStart = Double(layout.introBars * 4) * beat
        let breakEnd = breakStart + Double(layout.breakBars * 4) * beat

        // Continuous pad chord (no clicks), quieter during the break.
        for i in 0..<x.count {
            let tt = Double(i) / sr
            x[i] = Float(0.05 * (sin(2 * .pi * 220 * tt) + sin(2 * .pi * 277.2 * tt) + sin(2 * .pi * 329.6 * tt)))
        }
        func add(_ t: Double, length: Double, _ f: (Double) -> Float) {
            let start = Int(t * sr)
            for i in 0..<Int(length * sr) where start + i < x.count { x[start + i] += f(Double(i) / sr) }
        }
        for b in 0..<(bars * 4) {
            let t = Double(b) * beat
            let inBreak = t >= breakStart - 1e-6 && t < breakEnd - 1e-6
            if inBreak { continue }
            if b % 2 == 0 { // kick on 1, and on the "and" of 3 (rock pattern) so the downbeat is unambiguous
                let kickAt = b % 4 == 0 ? t : t + beat / 2
                add(kickAt, length: 0.25) { tt in Float(0.9 * exp(-tt * 18) * sin(2 * .pi * (55 + 90 * exp(-tt * 30)) * tt)) }
            } else { // snare
                snares.append(t)
                add(t, length: 0.2) { tt in
                    let noise = Float.random(in: -1...1, using: &rng)
                    return Float(exp(-tt * 22)) * (0.55 * noise + 0.3 * Float(sin(2 * .pi * 200 * tt)))
                }
            }
            for h in 0..<2 { // hats
                add(t + Double(h) * beat / 2, length: 0.04) { tt in Float(exp(-tt * 120)) * 0.12 * Float.random(in: -1...1, using: &rng) }
            }
        }
        return (MonoAudio(samples: x, sampleRate: sr), snares, breakStart...breakEnd)
    }
}

/// Deterministic xorshift generator so analyzer tests are reproducible.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
}
