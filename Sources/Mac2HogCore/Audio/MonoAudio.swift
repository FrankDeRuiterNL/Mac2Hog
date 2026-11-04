import Foundation

/// Mono PCM audio in the -1...1 range.
public struct MonoAudio: Sendable {
    public var samples: [Float]
    public var sampleRate: Double

    public init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    public var duration: Double { sampleRate > 0 ? Double(samples.count) / sampleRate : 0 }

    /// Mixes interleaved multichannel samples down to mono.
    public static func downmix(interleaved: [Float], channels: Int, sampleRate: Double) -> MonoAudio {
        guard channels > 1 else { return MonoAudio(samples: interleaved, sampleRate: sampleRate) }
        let frames = interleaved.count / channels
        var mono = [Float](repeating: 0, count: frames)
        let scale = 1 / Float(channels)
        interleaved.withUnsafeBufferPointer { src in
            for f in 0..<frames {
                var sum: Float = 0
                let base = f * channels
                for c in 0..<channels { sum += src[base + c] }
                mono[f] = sum * scale
            }
        }
        return MonoAudio(samples: mono, sampleRate: sampleRate)
    }

    /// Band-limited resampling (box pre-filter + linear interpolation); adequate for analysis.
    public func resampled(to target: Double) -> MonoAudio {
        guard sampleRate > 0, abs(target - sampleRate) > 0.5, !samples.isEmpty else { return self }
        let ratio = sampleRate / target
        var source = samples
        if ratio > 1 {
            // Moving average low-pass of width ~ratio to suppress aliasing.
            let width = max(1, Int(ratio.rounded(.up)))
            var filtered = [Float](repeating: 0, count: samples.count)
            var acc: Float = 0
            for i in 0..<samples.count {
                acc += samples[i]
                if i >= width { acc -= samples[i - width] }
                filtered[i] = acc / Float(min(i + 1, width))
            }
            source = filtered
        }
        let outCount = Int(Double(samples.count) / ratio)
        var out = [Float](repeating: 0, count: outCount)
        let delay = ratio > 1 ? (ratio.rounded(.up) - 1) / 2 : 0
        for i in 0..<outCount {
            let pos = Double(i) * ratio + delay
            let i0 = Int(pos)
            guard i0 < source.count - 1 else { out[i] = source[min(i0, source.count - 1)]; continue }
            let frac = Float(pos - Double(i0))
            out[i] = source[i0] * (1 - frac) + source[i0 + 1] * frac
        }
        return MonoAudio(samples: out, sampleRate: target)
    }
}
