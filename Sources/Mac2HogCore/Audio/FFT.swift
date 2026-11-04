import Foundation

/// Iterative radix-2 FFT for real input, returning magnitudes of the positive spectrum.
public final class RealFFT {
    public let size: Int
    private let log2n: Int
    private let cosTable: [Float]
    private let sinTable: [Float]
    private let bitReverse: [Int]
    public let window: [Float]
    private var re: [Float]
    private var im: [Float]

    public init(size: Int) {
        precondition(size > 1 && size & (size - 1) == 0, "FFT size must be a power of two")
        self.size = size
        log2n = Int(log2(Double(size)))
        cosTable = (0..<size / 2).map { Float(cos(-2 * Double.pi * Double($0) / Double(size))) }
        sinTable = (0..<size / 2).map { Float(sin(-2 * Double.pi * Double($0) / Double(size))) }
        bitReverse = (0..<size).map { i in
            var r = 0, x = i
            for _ in 0..<Int(log2(Double(size))) { r = (r << 1) | (x & 1); x >>= 1 }
            return r
        }
        window = (0..<size).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(size))) } // Hann
        re = [Float](repeating: 0, count: size)
        im = [Float](repeating: 0, count: size)
    }

    /// Magnitude spectrum (size/2 + 1 bins) of a windowed frame starting at `offset`.
    public func magnitudes(of signal: [Float], offset: Int, into out: inout [Float]) {
        let n = size
        for i in 0..<n {
            let idx = offset + i
            let s: Float = (idx >= 0 && idx < signal.count) ? signal[idx] : 0
            re[bitReverse[i]] = s * window[i]
            im[bitReverse[i]] = 0
        }
        var len = 2
        while len <= n {
            let half = len / 2
            let step = n / len
            var start = 0
            while start < n {
                for k in 0..<half {
                    let wr = cosTable[k * step], wi = sinTable[k * step]
                    let a = start + k, b = a + half
                    let tr = re[b] * wr - im[b] * wi
                    let ti = re[b] * wi + im[b] * wr
                    re[b] = re[a] - tr; im[b] = im[a] - ti
                    re[a] += tr; im[a] += ti
                }
                start += len
            }
            len <<= 1
        }
        if out.count != n / 2 + 1 { out = [Float](repeating: 0, count: n / 2 + 1) }
        for k in 0...(n / 2) { out[k] = (re[k] * re[k] + im[k] * im[k]).squareRoot() }
    }
}
