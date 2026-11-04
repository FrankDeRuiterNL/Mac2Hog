import Foundation

/// Generates SMPTE linear timecode (LTC) audio so the Hog 4 can chase the song via its LTC input.
public enum LTCEncoder {
    static let sync: [UInt8] = [0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1]

    /// The 80 bits (LSB first per field) for one timecode frame.
    public static func bits(for tc: Timecode) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 80)
        func put(_ value: Int, at start: Int, count: Int) {
            for i in 0..<count { b[start + i] = UInt8((value >> i) & 1) }
        }
        put(tc.frames % 10, at: 0, count: 4)
        put(tc.frames / 10, at: 8, count: 2)
        b[10] = tc.rate.isDropFrame ? 1 : 0
        put(tc.seconds % 10, at: 16, count: 4)
        put(tc.seconds / 10, at: 24, count: 3)
        put(tc.minutes % 10, at: 32, count: 4)
        put(tc.minutes / 10, at: 40, count: 3)
        put(tc.hours % 10, at: 48, count: 4)
        put(tc.hours / 10, at: 56, count: 2)
        for i in 0..<16 { b[64 + i] = sync[i] }
        // Polarity correction bit: bit 59 at 25 fps, bit 27 otherwise; makes the number of zeros even.
        let parityBit = tc.rate == .fps25 ? 59 : 27
        b[parityBit] = 0
        if b.filter({ $0 == 0 }).count % 2 != 0 { b[parityBit] = 1 }
        return b
    }

    /// Renders biphase-mark LTC audio starting at `start` for `duration` seconds.
    public static func render(start: Timecode, duration: Double, sampleRate: Double, amplitude: Float = 0.5) -> [Float] {
        let rate = start.rate
        let totalSamples = Int(duration * sampleRate)
        var out = [Float](repeating: 0, count: totalSamples)
        let samplesPerBit = sampleRate / (rate.fps * 80)
        var level: Float = amplitude
        var frameNumber = start.frameNumber
        var position = 0.0
        var sample = 0
        while sample < totalSamples {
            let bits = bits(for: Timecode(frameNumber: frameNumber, rate: rate))
            for bit in bits {
                let bitEnd = position + samplesPerBit
                let mid = position + samplesPerBit / 2
                level = -level // transition at every bit boundary
                while Double(sample) < bitEnd && sample < totalSamples {
                    if bit == 1 && Double(sample) >= mid && Double(sample) < mid + 1 { level = -level }
                    out[sample] = level
                    sample += 1
                }
                position = bitEnd
            }
            frameNumber += 1
        }
        return out
    }

    /// Decodes LTC audio back to timecodes (used for self-tests).
    public static func decode(_ samples: [Float], sampleRate: Double, rate: TimecodeRate) -> [Timecode] {
        let samplesPerBit = sampleRate / (rate.fps * 80)
        var transitions: [Int] = []
        for i in 1..<samples.count where (samples[i] >= 0) != (samples[i - 1] >= 0) { transitions.append(i) }
        var bits: [UInt8] = []
        var i = 0
        while i + 1 < transitions.count {
            let gap = Double(transitions[i + 1] - transitions[i])
            if gap < samplesPerBit * 0.75 {
                bits.append(1); i += 2
            } else {
                bits.append(0); i += 1
            }
        }
        var result: [Timecode] = []
        var k = 0
        while k + 80 <= bits.count {
            if Array(bits[(k + 64)..<(k + 80)]) == sync {
                let w = Array(bits[k..<(k + 80)])
                func get(_ s: Int, _ c: Int) -> Int { (0..<c).reduce(0) { $0 | Int(w[s + $1]) << $1 } }
                result.append(Timecode(hours: get(48, 4) + 10 * get(56, 2), minutes: get(32, 4) + 10 * get(40, 3),
                                       seconds: get(16, 4) + 10 * get(24, 3), frames: get(0, 4) + 10 * get(8, 2), rate: rate))
                k += 80
            } else { k += 1 }
        }
        return result
    }
}
