import Foundation

/// Music analysis: tempo, beat grid, snare/kick hits, breaks and song structure.
///
/// Pipeline (all on a 22.05 kHz mono signal):
/// 1. STFT (1024 Hann, hop 256 → ~11.6 ms resolution) and log-compressed magnitudes.
/// 2. Spectral-flux onset envelopes: full band, kick band (40–150 Hz) and a snare score
///    (linear flux of the 1.2–5 kHz rattle, boosted by 150–400 Hz body, suppressed when the
///    onset is dominated by the kick band).
/// 3. Tempo from the autocorrelation of the onset envelope with a perceptual prior around 120 BPM.
/// 4. Beat tracking by dynamic programming (Ellis 2007), downbeats from kick/snare placement.
/// 5. Snare and kick hits by adaptive peak picking, boosted when they line up with the grid.
/// 6. Structure from a bar-level self-similarity matrix (Foote novelty), labelled by energy & repetition.
/// 7. Breaks: stretches of at least a bar where drums disappear or the level drops sharply.
public final class AudioAnalyzer {
    public struct Options: Sendable {
        public var minBPM: Double = 60
        public var maxBPM: Double = 200
        public var preferredBPM: Double = 120
        public var beatsPerBar: Int = 4
        /// 0...1, higher = fewer snare hits reported.
        public var snareSensitivity: Double = 0.5
        /// Minimum section length in bars.
        public var minSectionBars: Int = 4
        public init() {}
    }

    public var options: Options
    public init(options: Options = Options()) { self.options = options }

    let analysisRate = 22_050.0
    let fftSize = 1024
    let hop = 256
    var frameRate: Double { analysisRate / Double(hop) }
    /// Flux peaks once the onset is well inside the analysis window; this re-centres frame times.
    var frameLatency: Double { Double(fftSize) * 0.75 / analysisRate }
    func time(ofFrame f: Double) -> Double { f / frameRate + frameLatency }
    func frame(ofTime t: Double) -> Double { (t - frameLatency) * frameRate }

    // MARK: - Public entry point

    public func analyze(_ audio: MonoAudio, progress: ((Double, String) -> Void)? = nil) -> AnalysisResult {
        let report = progress ?? { _, _ in }
        report(0.02, "Preparing audio")
        let waveform = Self.waveformOverview(audio.samples, bins: 4000)
        let signal = audio.resampled(to: analysisRate).samples
        let duration = audio.duration

        report(0.1, "Computing spectrum")
        let features = computeFeatures(signal, progress: { report(0.1 + 0.5 * $0, "Computing spectrum") })

        report(0.62, "Estimating tempo")
        let candidates = estimateTempo(features.onset)
        let bpm = candidates.first?.bpm ?? options.preferredBPM

        report(0.7, "Tracking beats")
        let beatFrames = trackBeats(features.onset, bpm: bpm)
        let beats = assignBars(beatFrames, features: features)

        report(0.78, "Detecting snare and kick hits")
        let beatTimes = beats.map(\.time)
        let snares = pickHits(features.snare, beatTimes: beatTimes, bpm: bpm, sensitivity: options.snareSensitivity,
                              preferred: beats.filter { $0.beatInBar % 2 == 0 }.map(\.time))
        let kicks = pickHits(features.kick, beatTimes: beatTimes, bpm: bpm, sensitivity: 0.5,
                             preferred: beatTimes)

        report(0.86, "Finding song structure")
        let energyCurve = smoothedEnergy(features.rms)
        let breaks = detectBreaks(features: features, beats: beats)
        let sections = detectSections(features: features, beats: beats, duration: duration, breaks: breaks)

        report(1.0, "Done")
        return AnalysisResult(duration: duration, bpm: (bpm * 10).rounded() / 10, tempoCandidates: candidates,
                              beatsPerBar: options.beatsPerBar, beats: beats, snares: snares, kicks: kicks,
                              sections: sections, breaks: breaks, waveform: waveform,
                              energy: energyCurve, energyRate: frameRate / 8)
    }

    // MARK: - Features

    struct Features {
        var onset: [Float] = []      // full-band spectral flux
        var kick: [Float] = []       // low-band flux
        var snare: [Float] = []      // snare score (body × rattle)
        var snareBody: [Float] = []
        var snareRattle: [Float] = []
        var rms: [Float] = []        // frame RMS
        var bands: [[Float]] = []    // 12 log-spaced band energies per frame (log)
        var chroma: [[Float]] = []   // 12 pitch classes per frame
        var count: Int { onset.count }
    }

    func computeFeatures(_ signal: [Float], progress: (Double) -> Void) -> Features {
        let fft = RealFFT(size: fftSize)
        let binHz = analysisRate / Double(fftSize)
        let nBins = fftSize / 2 + 1
        let frames = max(1, (signal.count - fftSize) / hop + 1)
        func bin(_ hz: Double) -> Int { min(nBins - 1, max(1, Int(hz / binHz))) }

        let kickRange = bin(40)...bin(150)
        let snareBody = bin(150)...bin(400)
        let snareRattle = bin(1200)...bin(5000)

        // Log-spaced band edges 60 Hz .. 10 kHz
        let edges = (0...12).map { bin(60 * pow(10_000 / 60, Double($0) / 12)) }
        // Chroma map for bins 55 Hz .. 2 kHz
        var chromaOf = [Int](repeating: -1, count: nBins)
        for k in bin(55)...bin(2000) {
            let f = Double(k) * binHz
            let midi = 69 + 12 * log2(f / 440)
            chromaOf[k] = ((Int(midi.rounded()) % 12) + 12) % 12
        }

        var f = Features()
        f.onset.reserveCapacity(frames); f.kick.reserveCapacity(frames); f.snare.reserveCapacity(frames)
        var lowShare: [Float] = []
        lowShare.reserveCapacity(frames)
        var mag = [Float](repeating: 0, count: nBins)
        var prevLin = [Float](repeating: 0, count: nBins)
        var prev = [Float](repeating: 0, count: nBins)
        var cur = [Float](repeating: 0, count: nBins)

        for t in 0..<frames {
            let offset = t * hop
            fft.magnitudes(of: signal, offset: offset, into: &mag)
            var flux: Float = 0, kick: Float = 0, body: Float = 0, rattle: Float = 0, rattleLog: Float = 0
            for k in 0..<nBins {
                cur[k] = log(1 + 100 * mag[k])
                let d = max(0, cur[k] - prev[k])
                flux += d
                if kickRange.contains(k) { kick += d }
                if snareRattle.contains(k) { rattleLog += d }
                // Snare bands use linear-magnitude flux so loudness differences (snare vs hats) survive.
                let dl = max(0, mag[k] - prevLin[k])
                if snareBody.contains(k) { body += dl }
                if snareRattle.contains(k) { rattle += dl }
                prevLin[k] = mag[k]
            }
            f.onset.append(flux)
            f.kick.append(kick / Float(kickRange.count))
            f.snareBody.append(body / Float(snareBody.count))
            f.snareRattle.append(rattle / Float(snareRattle.count))
            let lowAvg = kick / Float(kickRange.count), highAvg = rattleLog / Float(snareRattle.count)
            lowShare.append(lowAvg + highAvg > 1e-6 ? lowAvg / (lowAvg + highAvg) : 1)
            swap(&prev, &cur)

            var energy: Float = 0
            let end = min(signal.count, offset + hop * 2)
            if offset < end { for i in offset..<end { energy += signal[i] * signal[i] } }
            f.rms.append((energy / Float(max(1, end - offset))).squareRoot())

            var bands = [Float](repeating: 0, count: 12)
            for b in 0..<12 {
                var s: Float = 0
                for k in edges[b]..<max(edges[b] + 1, edges[b + 1]) { s += mag[k] * mag[k] }
                bands[b] = log(1 + s)
            }
            f.bands.append(bands)
            var chroma = [Float](repeating: 0, count: 12)
            for k in 0..<nBins where chromaOf[k] >= 0 { chroma[chromaOf[k]] += mag[k] }
            f.chroma.append(chroma)
            if t % 2048 == 0 { progress(Double(t) / Double(frames)) }
        }
        f.onset = Self.normalize(Self.highPass(f.onset))
        f.kick = Self.normalize(Self.highPass(f.kick))

        // A snare needs both a tonal body (kicks lack the rattle) and broadband rattle (hats lack the body).
        let body = Self.normalize(Self.highPass(f.snareBody))
        let rattle = Self.normalize(Self.highPass(f.snareRattle))
        // Kicks have a broadband click too: subtract low-band onset strength.
        // Kicks also have a broadband click: weight by how little of the onset is in the kick band.
        f.snare = Self.normalize((0..<body.count).map { i in
            let weight = max(0, min(1, (0.9 - lowShare[i]) / 0.3))
            return rattle[i] * (0.7 + 0.3 * body[i]) * weight
        })
        f.snareBody = []; f.snareRattle = []
        return f
    }

    /// Removes slow trends (local mean over ~0.5 s) and half-wave rectifies.
    static func highPass(_ x: [Float], radius: Int = 22) -> [Float] {
        guard !x.isEmpty else { return x }
        var prefix = [Float](repeating: 0, count: x.count + 1)
        for i in 0..<x.count { prefix[i + 1] = prefix[i] + x[i] }
        return (0..<x.count).map { i in
            let lo = max(0, i - radius), hi = min(x.count, i + radius + 1)
            let mean = (prefix[hi] - prefix[lo]) / Float(hi - lo)
            return max(0, x[i] - mean)
        }
    }

    static func normalize(_ x: [Float]) -> [Float] {
        guard let m = x.max(), m > 0 else { return x }
        return x.map { $0 / m }
    }

    static func waveformOverview(_ samples: [Float], bins: Int) -> [Float] {
        guard !samples.isEmpty else { return [] }
        let n = min(bins, samples.count)
        let per = Double(samples.count) / Double(n)
        var out = [Float](repeating: 0, count: n)
        for b in 0..<n {
            let lo = Int(Double(b) * per), hi = min(samples.count, Int(Double(b + 1) * per))
            var peak: Float = 0
            var i = lo
            while i < hi { peak = max(peak, abs(samples[i])); i += 1 }
            out[b] = peak
        }
        return normalize(out)
    }

    func smoothedEnergy(_ rms: [Float]) -> [Float] {
        let step = 8
        var out: [Float] = []
        var i = 0
        while i < rms.count {
            let s = rms[i..<min(rms.count, i + step)]
            out.append(s.reduce(0, +) / Float(s.count))
            i += step
        }
        return Self.normalize(out)
    }

    // MARK: - Tempo

    func estimateTempo(_ onset: [Float]) -> [TempoCandidate] {
        let fr = frameRate
        let minLag = max(1, Int(fr * 60 / options.maxBPM))
        let maxLag = Int(fr * 60 / options.minBPM)
        guard onset.count > maxLag * 2 else { return [TempoCandidate(bpm: options.preferredBPM, confidence: 0)] }

        let mean = onset.reduce(0, +) / Float(onset.count)
        let x = onset.map { $0 - mean }
        var ac = [Double](repeating: 0, count: maxLag * 2 + 2)
        for lag in 0..<ac.count where lag < x.count {
            var s: Double = 0
            for i in 0..<(x.count - lag) { s += Double(x[i] * x[i + lag]) }
            ac[lag] = s / Double(x.count - lag)
        }
        let zero = max(ac[0], 1e-9)

        // Score each lag: autocorrelation + harmonic support, weighted by a log-normal tempo prior.
        var scores = [Double](repeating: -.infinity, count: maxLag + 1)
        for lag in minLag...maxLag {
            let bpm = 60 * fr / Double(lag)
            let prior = exp(-0.5 * pow(log2(bpm / options.preferredBPM) / 1.0, 2))
            let harmonic = ac[lag] + 0.5 * ac[min(ac.count - 1, lag * 2)] + 0.25 * ac[lag / 2]
            scores[lag] = harmonic / zero * prior
        }
        var peaks: [(lag: Double, score: Double)] = []
        for lag in (minLag + 1)..<maxLag where scores[lag] > scores[lag - 1] && scores[lag] >= scores[lag + 1] && scores[lag] > 0 {
            // Parabolic interpolation for sub-frame lag precision.
            let a = scores[lag - 1], b = scores[lag], c = scores[lag + 1]
            let denom = a - 2 * b + c
            let delta = denom == 0 ? 0 : 0.5 * (a - c) / denom
            peaks.append((Double(lag) + max(-0.5, min(0.5, delta)), b))
        }
        peaks.sort { $0.score > $1.score }
        guard let best = peaks.first else { return [TempoCandidate(bpm: options.preferredBPM, confidence: 0)] }
        var out: [TempoCandidate] = []
        for p in peaks {
            let bpm = 60 * fr / p.lag
            if out.contains(where: { abs($0.bpm - bpm) < 2 }) { continue }
            out.append(TempoCandidate(bpm: (bpm * 10).rounded() / 10, confidence: min(1, p.score / best.score)))
            if out.count == 4 { break }
        }
        // Refine the winner with a fine comb search around the coarse estimate.
        out[0].bpm = refineTempo(onset, around: out[0].bpm)
        return out
    }

    func refineTempo(_ onset: [Float], around bpm: Double) -> Double {
        let fr = frameRate
        var bestBPM = bpm, bestScore = -Double.infinity
        var candidate = bpm - 1.5
        while candidate <= bpm + 1.5 {
            let period = 60 * fr / candidate
            // Best phase for this tempo
            var maxScore = 0.0
            let phases = Int(period)
            for phase in stride(from: 0, to: phases, by: 1) {
                var s = 0.0
                var t = Double(phase)
                var n = 0
                while Int(t) < onset.count { s += Double(onset[Int(t)]); t += period; n += 1 }
                if n > 0 { maxScore = max(maxScore, s / Double(n)) }
            }
            if maxScore > bestScore { bestScore = maxScore; bestBPM = candidate }
            candidate += 0.05
        }
        return (bestBPM * 100).rounded() / 100
    }

    // MARK: - Beats

    /// Dynamic-programming beat tracker. Returns beat positions in frames.
    func trackBeats(_ onset: [Float], bpm: Double) -> [Double] {
        let n = onset.count
        guard n > 0, bpm > 0 else { return [] }
        let period = 60 * frameRate / bpm
        // Smooth onsets with a Gaussian ~ period/32 wide.
        let sigma = max(1, period / 32)
        let radius = Int(sigma * 3)
        let kernel = (-radius...radius).map { exp(-0.5 * pow(Double($0) / sigma, 2)) }
        var local = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var s = 0.0
            for (j, w) in kernel.enumerated() {
                let idx = i + j - radius
                if idx >= 0 && idx < n { s += Double(onset[idx]) * w }
            }
            local[i] = s
        }
        let alpha = 100.0
        var score = local
        var backlink = [Int](repeating: -1, count: n)
        let lo = Int(period / 2), hi = Int(period * 2)
        for i in 0..<n {
            var best = -Double.infinity, bestPrev = -1
            let start = max(0, i - hi), end = i - lo
            if end >= start {
                for prev in start...end {
                    let ratio = Double(i - prev) / period
                    let penalty = alpha * pow(log(ratio), 2)
                    let v = score[prev] - penalty
                    if v > best { best = v; bestPrev = prev }
                }
            }
            if bestPrev >= 0 && best > 0 { score[i] = local[i] + best; backlink[i] = bestPrev }
        }
        // Start backtracking from the highest score within the final beat period.
        let tailStart = max(0, n - Int(period) - 1)
        var idx = (tailStart..<n).max { score[$0] < score[$1] } ?? n - 1
        var beats: [Int] = []
        while idx >= 0 { beats.append(idx); idx = backlink[idx] }
        beats.reverse()
        // Extrapolate the grid into silent intro/outro so timecode-based triggers have beats everywhere.
        var result = beats.map(Double.init)
        if let first = result.first {
            var t = first - period
            while t >= 0 { result.insert(t, at: 0); t -= period }
        }
        if let last = result.last {
            var t = last + period
            while t < Double(n) { result.append(t); t += period }
        }
        return result
    }

    /// Picks which beat is "1" by comparing kick vs. snare energy at each of the bar positions.
    func assignBars(_ beatFrames: [Double], features: Features) -> [Beat] {
        let bpb = max(1, options.beatsPerBar)
        func value(_ x: [Float], _ frame: Double) -> Float {
            let c = Int(frame.rounded())
            var m: Float = 0
            for i in max(0, c - 3)...min(x.count - 1, c + 3) where x.count > 0 { m = max(m, x[i]) }
            return m
        }
        var phaseScore = [Float](repeating: 0, count: bpb)
        for (i, f) in beatFrames.enumerated() {
            let k = value(features.kick, f), s = value(features.snare, f)
            for phase in 0..<bpb {
                let pos = ((i - phase) % bpb + bpb) % bpb
                if pos == 0 { phaseScore[phase] += k - 0.5 * s }       // downbeat: kick, no snare
                if bpb == 4 && pos % 2 == 1 { phaseScore[phase] += 0.5 * s } // backbeat snare on 2 & 4
            }
        }
        let phase = phaseScore.indices.max { phaseScore[$0] < phaseScore[$1] } ?? 0
        return beatFrames.enumerated().map { i, f in
            let rel = i - phase
            let bar = Int(floor(Double(rel) / Double(bpb))) + 1
            let pos = ((rel % bpb) + bpb) % bpb + 1
            return Beat(time: max(0, time(ofFrame: f)), bar: bar, beatInBar: pos)
        }
    }

    // MARK: - Hits

    func pickHits(_ env: [Float], beatTimes: [Double], bpm: Double, sensitivity: Double, preferred: [Double]) -> [Hit] {
        let n = env.count
        guard n > 2 else { return [] }
        let fr = frameRate
        let win = Int(fr * 1.5)
        // Adaptive threshold: local median + k * local MAD-ish spread.
        var hits: [Hit] = []
        let minGap = max(2, Int(fr * min(0.12, 60 / bpm / 3)))
        var lastFrame = -minGap
        let k = Float(1.0 + 3.0 * sensitivity)
        var windowValues: [Float] = []
        let stride = 8
        var thresholds = [Float](repeating: 0, count: n)
        var i = 0
        while i < n {
            let lo = max(0, i - win), hi = min(n, i + win)
            windowValues = Array(env[lo..<hi]).sorted()
            let med = windowValues[windowValues.count / 2]
            let q90 = windowValues[min(windowValues.count - 1, Int(Double(windowValues.count) * 0.9))]
            // Also require a fraction of the loudest nearby hit so ghost notes / bleed are ignored.
            let localMax = windowValues.last ?? 0
            let th = max(med + k * max(0.02, (q90 - med) / 2), localMax * Float(0.2 + 0.4 * sensitivity))
            for j in i..<min(n, i + stride) { thresholds[j] = th }
            i += stride
        }
        let grid = beatTimes.sorted()
        let pref = preferred.sorted()
        let tolerance = min(0.07, 60 / bpm / 6)
        for t in 1..<(n - 1) {
            let v = env[t]
            guard v >= env[t - 1], v > env[t + 1], v > max(0.08, thresholds[t] * 0.75) else { continue }
            let time = self.time(ofFrame: Double(t))
            let onGrid = Self.nearest(grid, to: time) < tolerance
            let preferredHit = Self.nearest(pref, to: time) < tolerance
            // Hits on the expected grid positions need less evidence.
            let required = preferredHit ? thresholds[t] * 0.75 : (onGrid ? thresholds[t] : thresholds[t] * 1.5)
            guard v > required else { continue }
            if t - lastFrame < minGap {
                if let last = hits.last, Double(v) > last.strength {
                    hits[hits.count - 1] = Hit(time: time, strength: Double(v), onGrid: onGrid || preferredHit)
                    lastFrame = t
                }
                continue
            }
            hits.append(Hit(time: time, strength: Double(v), onGrid: onGrid || preferredHit))
            lastFrame = t
        }
        let maxStrength = hits.map(\.strength).max() ?? 1
        return hits.map { Hit(time: $0.time, strength: $0.strength / maxStrength, onGrid: $0.onGrid) }
    }

    static func nearest(_ sorted: [Double], to t: Double) -> Double {
        guard !sorted.isEmpty else { return .infinity }
        var lo = 0, hi = sorted.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        var d = abs(sorted[lo] - t)
        if lo > 0 { d = min(d, abs(sorted[lo - 1] - t)) }
        return d
    }

    // MARK: - Bars

    struct BarFeature {
        var start: Double
        var end: Double
        var vector: [Double]
        var rms: Double
        var drums: Double
    }

    func barFeatures(features: Features, beats: [Beat]) -> [BarFeature] {
        let downbeats = beats.filter { $0.beatInBar == 1 }.map(\.time)
        guard downbeats.count >= 2 else { return [] }
        var bars: [BarFeature] = []
        for i in 0..<(downbeats.count - 1) {
            let a = max(0, Int(frame(ofTime: downbeats[i]))), b = min(features.count, Int(frame(ofTime: downbeats[i + 1])))
            guard b > a else { continue }
            var bands = [Double](repeating: 0, count: 12), chroma = [Double](repeating: 0, count: 12)
            var rms = 0.0, drums = 0.0
            for t in a..<b {
                for j in 0..<12 { bands[j] += Double(features.bands[t][j]); chroma[j] += Double(features.chroma[t][j]) }
                rms += Double(features.rms[t])
                drums += Double(features.kick[t] + features.snare[t])
            }
            let n = Double(b - a)
            bands = bands.map { $0 / n }
            let cmax = max(chroma.max() ?? 1, 1e-9)
            chroma = chroma.map { $0 / cmax }
            bars.append(BarFeature(start: downbeats[i], end: downbeats[i + 1], vector: bands + chroma, rms: rms / n, drums: drums / n))
        }
        return bars
    }

    // MARK: - Breaks

    func detectBreaks(features: Features, beats: [Beat]) -> [BreakRegion] {
        let bars = barFeatures(features: features, beats: beats)
        guard bars.count >= 4 else { return [] }
        let medRMS = Self.median(bars.map(\.rms))
        let medDrums = Self.median(bars.map(\.drums))
        var regions: [BreakRegion] = []
        var current: BreakRegion?
        for (i, bar) in bars.enumerated() {
            // Ignore the very start/end; those are intro/outro rather than breaks.
            let interior = i > 0 && i < bars.count - 1
            let quiet = bar.rms < medRMS * 0.45
            let noDrums = bar.drums < medDrums * 0.3
            if interior && (quiet || noDrums) {
                if current == nil { current = BreakRegion(start: bar.start, end: bar.end) } else { current?.end = bar.end }
            } else if let c = current {
                regions.append(c); current = nil
            }
        }
        if let c = current { regions.append(c) }
        return regions
    }

    // MARK: - Sections

    func detectSections(features: Features, beats: [Beat], duration: Double, breaks: [BreakRegion]) -> [SongSection] {
        let bars = barFeatures(features: features, beats: beats)
        guard bars.count >= options.minSectionBars * 2 else {
            return [SongSection(start: 0, end: duration, kind: .section, name: "Song", group: "A", energy: 1)]
        }
        // Standardise feature dimensions, then cosine self-similarity.
        let dims = bars[0].vector.count
        var means = [Double](repeating: 0, count: dims), stds = [Double](repeating: 0, count: dims)
        for b in bars { for d in 0..<dims { means[d] += b.vector[d] } }
        means = means.map { $0 / Double(bars.count) }
        for b in bars { for d in 0..<dims { stds[d] += pow(b.vector[d] - means[d], 2) } }
        stds = stds.map { max(1e-6, ($0 / Double(bars.count)).squareRoot()) }
        let vecs: [[Double]] = bars.map { b in (0..<dims).map { (b.vector[$0] - means[$0]) / stds[$0] } + [b.drums * 4] }
        let n = vecs.count
        var ssm = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n { for j in i..<n { let s = Self.cosine(vecs[i], vecs[j]); ssm[i][j] = s; ssm[j][i] = s } }

        // Foote novelty with a Gaussian-tapered checkerboard kernel.
        let K = max(2, options.minSectionBars)
        var novelty = [Double](repeating: 0, count: n)
        for c in 0..<n {
            var s = 0.0
            for i in -K..<K { for j in -K..<K {
                let a = c + i, b = c + j
                guard a >= 0, b >= 0, a < n, b < n else { continue }
                let sign: Double = ((i < 0) == (j < 0)) ? 1 : -1
                let w = exp(-0.5 * (pow(Double(i) + 0.5, 2) + pow(Double(j) + 0.5, 2)) / pow(Double(K) / 2, 2))
                s += sign * w * ssm[a][b]
            } }
            novelty[c] = max(0, s)
        }
        // Energy jumps are strong structural cues in pop/EDM.
        for c in 1..<n {
            let jump = abs(log((bars[c].rms + 1e-6) / (bars[c - 1].rms + 1e-6)))
            novelty[c] += jump * 2
        }
        let mean = novelty.reduce(0, +) / Double(n)
        let sd = (novelty.map { pow($0 - mean, 2) }.reduce(0, +) / Double(n)).squareRoot()
        let threshold = mean + 0.3 * sd

        var boundaries: [Int] = [0]
        let candidates = (1..<n).filter { c in
            novelty[c] > threshold &&
            (max(0, c - 2)...min(n - 1, c + 2)).allSatisfy { novelty[$0] <= novelty[c] }
        }.sorted { novelty[$0] > novelty[$1] }
        for c in candidates {
            // Prefer phrase boundaries (multiples of 4 bars) when a neighbour is equally strong.
            var best = c
            for d in [-1, 1] where c + d > 0 && c + d < n && (c + d) % 4 == 0 && novelty[c + d] > novelty[c] * 0.8 { best = c + d }
            if boundaries.allSatisfy({ abs($0 - best) >= options.minSectionBars }) && n - best >= options.minSectionBars / 2 {
                boundaries.append(best)
            }
        }
        // Ensure break regions start/end sections.
        for br in breaks {
            for t in [br.start, br.end] {
                if let idx = bars.firstIndex(where: { abs($0.start - t) < 0.05 }),
                   boundaries.allSatisfy({ abs($0 - idx) >= 2 }) { boundaries.append(idx) }
            }
        }
        boundaries.sort()

        // Build raw sections.
        struct Raw { var a: Int; var b: Int; var vec: [Double]; var rms: Double; var drums: Double }
        var raws: [Raw] = []
        for (k, a) in boundaries.enumerated() {
            let b = k + 1 < boundaries.count ? boundaries[k + 1] : n
            guard b > a else { continue }
            var v = [Double](repeating: 0, count: vecs[0].count)
            var rms = 0.0, drums = 0.0
            for i in a..<b { for d in 0..<v.count { v[d] += vecs[i][d] }; rms += bars[i].rms; drums += bars[i].drums }
            raws.append(Raw(a: a, b: b, vec: v.map { $0 / Double(b - a) }, rms: rms / Double(b - a), drums: drums / Double(b - a)))
        }

        // Group similar sections (A, B, C …).
        var groups: [Int] = []
        var groupVecs: [[Double]] = []
        for r in raws {
            if let g = groupVecs.firstIndex(where: { Self.cosine($0, r.vec) > 0.8 }) { groups.append(g) }
            else { groupVecs.append(r.vec); groups.append(groupVecs.count - 1) }
        }

        let maxRMS = raws.map(\.rms).max() ?? 1
        let energies = raws.map { $0.rms / maxRMS }
        let sortedE = energies.sorted()
        let highCut = sortedE[min(sortedE.count - 1, Int(Double(sortedE.count) * 0.6))]
        let medDrums = Self.median(raws.map(\.drums))

        var kinds: [SectionKind] = []
        for (i, r) in raws.enumerated() {
            let e = energies[i]
            let startT = bars[r.a].start, endT = r.b < n ? bars[r.b].start : bars[n - 1].end
            let isBreak = breaks.contains { $0.start < endT - 0.1 && $0.end > startT + 0.1 && $0.duration >= (endT - startT) * 0.5 }
            var kind: SectionKind
            if i == 0 && (e < highCut || raws.count > 2) { kind = .intro }
            else if i == raws.count - 1 && e < highCut { kind = .outro }
            else if isBreak || (e < 0.5 && r.drums < medDrums * 0.5) { kind = .breakdown }
            else if e >= highCut { kind = .chorus }
            else { kind = .verse }
            kinds.append(kind)
        }
        // A section right before a chorus whose loudness rises steadily is a build-up.
        for i in 0..<(raws.count - 1) where kinds[i] == .verse || kinds[i] == .breakdown {
            guard kinds[i + 1] == .chorus, raws[i].b - raws[i].a >= 2 else { continue }
            let firstHalf = bars[raws[i].a..<(raws[i].a + (raws[i].b - raws[i].a) / 2)].map(\.rms)
            let secondHalf = bars[(raws[i].a + (raws[i].b - raws[i].a) / 2)..<raws[i].b].map(\.rms)
            if Self.mean(secondHalf) > Self.mean(firstHalf) * 1.25 { kinds[i] = .buildUp }
        }
        // A unique, non-repeating mid-song group between choruses becomes the bridge.
        let groupCounts = groups.reduce(into: [Int: Int]()) { $0[$1, default: 0] += 1 }
        if let lastChorus = kinds.lastIndex(of: .chorus) {
            for i in 1..<max(1, lastChorus) where kinds[i] == .verse && groupCounts[groups[i]] == 1
                && kinds[..<i].contains(.chorus) { kinds[i] = .bridge }
        }

        var counters: [SectionKind: Int] = [:]
        let totals = kinds.reduce(into: [SectionKind: Int]()) { $0[$1, default: 0] += 1 }
        var sections: [SongSection] = []
        for (i, r) in raws.enumerated() {
            let start = i == 0 ? 0 : bars[r.a].start
            let end = i == raws.count - 1 ? duration : bars[r.b].start
            counters[kinds[i], default: 0] += 1
            let base = kinds[i] == .chorus ? "Chorus" : kinds[i].displayName
            let name = (totals[kinds[i]] ?? 0) > 1 ? "\(base) \(counters[kinds[i]]!)" : base
            let letter = String(UnicodeScalar(UInt8(65 + groups[i] % 26)))
            sections.append(SongSection(start: start, end: end, kind: kinds[i], name: name, group: letter, energy: energies[i]))
        }
        return sections
    }

    // MARK: - Math helpers

    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<min(a.count, b.count) { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : 0
    }

    static func median(_ x: [Double]) -> Double {
        guard !x.isEmpty else { return 0 }
        let s = x.sorted()
        return s[s.count / 2]
    }

    static func mean(_ x: [Double]) -> Double { x.isEmpty ? 0 : x.reduce(0, +) / Double(x.count) }
}
