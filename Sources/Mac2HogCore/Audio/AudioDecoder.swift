import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

public enum AudioDecoderError: Error, LocalizedError {
    case unsupportedFormat(String)
    case readFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let s): return "Unsupported audio format: \(s)"
        case .readFailed(let s): return "Could not read audio file: \(s)"
        }
    }
}

/// Decodes .wav / .mp3 (and anything else Core Audio understands on macOS) into mono floats.
public enum AudioDecoder {
    public static let supportedExtensions = ["wav", "wave", "mp3", "aif", "aiff", "m4a", "caf"]

    public static func decode(url: URL) throws -> MonoAudio {
        #if canImport(AVFoundation)
        return try decodeWithAVFoundation(url: url)
        #else
        let ext = url.pathExtension.lowercased()
        guard ext == "wav" || ext == "wave" else {
            throw AudioDecoderError.unsupportedFormat("\(ext) (only WAV is supported on this platform)")
        }
        return try WAVDecoder.decode(data: Data(contentsOf: url))
        #endif
    }

    #if canImport(AVFoundation)
    static func decodeWithAVFoundation(url: URL) throws -> MonoAudio {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw AudioDecoderError.readFailed(error.localizedDescription) }
        let format = file.processingFormat // deinterleaved Float32
        let channels = Int(format.channelCount)
        let total = AVAudioFrameCount(file.length)
        var mono = [Float]()
        mono.reserveCapacity(Int(total))
        let chunk: AVAudioFrameCount = 1 << 16
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw AudioDecoderError.readFailed("buffer allocation failed")
        }
        while file.framePosition < file.length {
            do { try file.read(into: buffer, frameCount: chunk) } catch { throw AudioDecoderError.readFailed(error.localizedDescription) }
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let data = buffer.floatChannelData else { throw AudioDecoderError.unsupportedFormat("non-float buffer") }
            let scale = 1 / Float(channels)
            for i in 0..<n {
                var s: Float = 0
                for c in 0..<channels { s += data[c][i] }
                mono.append(s * scale)
            }
        }
        return MonoAudio(samples: mono, sampleRate: format.sampleRate)
    }
    #endif
}

/// Portable RIFF/WAVE decoder (PCM 8/16/24/32-bit and IEEE float 32/64).
public enum WAVDecoder {
    public static func decode(data: Data) throws -> MonoAudio {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: bytes[8..<12], as: UTF8.self) == "WAVE" else {
            throw AudioDecoderError.unsupportedFormat("not a RIFF/WAVE file")
        }
        func u16(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }

        var offset = 12
        var formatTag = 0, channels = 0, sampleRate = 0, bits = 0
        var dataRange: Range<Int>?
        while offset + 8 <= bytes.count {
            let id = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
            let size = u32(offset + 4)
            let body = offset + 8
            if id == "fmt " {
                formatTag = u16(body); channels = u16(body + 2); sampleRate = u32(body + 4); bits = u16(body + 14)
                if formatTag == 0xFFFE, size >= 26 { formatTag = u16(body + 24) } // WAVE_FORMAT_EXTENSIBLE
            } else if id == "data" {
                dataRange = body..<min(bytes.count, body + size)
            }
            offset = body + size + (size & 1)
        }
        guard let range = dataRange, channels > 0, sampleRate > 0 else {
            throw AudioDecoderError.unsupportedFormat("missing fmt or data chunk")
        }
        let bytesPerSample = bits / 8
        let count = range.count / bytesPerSample
        var interleaved = [Float](repeating: 0, count: count)
        var p = range.lowerBound
        for i in 0..<count {
            switch (formatTag, bits) {
            case (1, 8): interleaved[i] = (Float(bytes[p]) - 128) / 128
            case (1, 16): interleaved[i] = Float(Int16(bitPattern: UInt16(u16(p)))) / 32768
            case (1, 24):
                var v = Int32(bytes[p]) | Int32(bytes[p + 1]) << 8 | Int32(bytes[p + 2]) << 16
                if v & 0x800000 != 0 { v |= ~0xFFFFFF }
                interleaved[i] = Float(v) / 8_388_608
            case (1, 32): interleaved[i] = Float(Int32(bitPattern: UInt32(u32(p)))) / 2_147_483_648
            case (3, 32): interleaved[i] = Float(bitPattern: UInt32(u32(p)))
            case (3, 64):
                let lo = UInt64(u32(p)), hi = UInt64(u32(p + 4))
                interleaved[i] = Float(Double(bitPattern: lo | hi << 32))
            default: throw AudioDecoderError.unsupportedFormat("format \(formatTag) / \(bits) bit")
            }
            p += bytesPerSample
        }
        return MonoAudio.downmix(interleaved: interleaved, channels: channels, sampleRate: Double(sampleRate))
    }

    /// Writes 16-bit PCM WAV (used for tests and LTC export).
    public static func encode16(samples: [Float], sampleRate: Int, channels: Int = 1) -> Data {
        var d = Data()
        func put32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        func put16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        let dataSize = samples.count * 2
        d.append(contentsOf: Array("RIFF".utf8)); put32(36 + dataSize); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); put32(16); put16(1); put16(channels); put32(sampleRate)
        put32(sampleRate * channels * 2); put16(channels * 2); put16(16)
        d.append(contentsOf: Array("data".utf8)); put32(dataSize)
        d.reserveCapacity(d.count + dataSize)
        for s in samples {
            let v = Int16(max(-1, min(1, s)) * 32767)
            withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
        }
        return d
    }
}
