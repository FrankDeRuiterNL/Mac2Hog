import Foundation

/// A single OSC argument. Hog 4 uses float, int and string payloads.
public enum OSCArgument: Equatable, Hashable, Codable, Sendable, CustomStringConvertible {
    case int(Int32)
    case float(Float)
    case string(String)

    var typeTag: Character {
        switch self {
        case .int: return "i"
        case .float: return "f"
        case .string: return "s"
        }
    }

    public var description: String {
        switch self {
        case .int(let v): return "\(v)"
        case .float(let v): return String(format: "%g", Double(v))
        case .string(let v): return "\"\(v)\""
        }
    }
}

/// An OSC 1.0 message with binary encoding / decoding.
public struct OSCMessage: Equatable, Hashable, Codable, Sendable, CustomStringConvertible {
    public var address: String
    public var arguments: [OSCArgument]

    public init(_ address: String, _ arguments: [OSCArgument] = []) {
        self.address = address
        self.arguments = arguments
    }

    public var description: String {
        arguments.isEmpty ? address : "\(address) " + arguments.map(\.description).joined(separator: " ")
    }

    // MARK: Encoding

    public func encoded() -> Data {
        var data = Data()
        data.appendOSCString(address)
        data.appendOSCString("," + String(arguments.map(\.typeTag)))
        for arg in arguments {
            switch arg {
            case .int(let v): data.appendBigEndian(UInt32(bitPattern: v))
            case .float(let v): data.appendBigEndian(v.bitPattern)
            case .string(let s): data.appendOSCString(s)
            }
        }
        return data
    }

    // MARK: Decoding

    public enum DecodeError: Error { case malformed }

    public static func decode(_ data: Data) throws -> OSCMessage {
        var cursor = data.startIndex
        let address = try data.readOSCString(at: &cursor)
        guard address.hasPrefix("/") else { throw DecodeError.malformed }
        guard cursor < data.endIndex else { return OSCMessage(address) }
        let tags = try data.readOSCString(at: &cursor)
        guard tags.hasPrefix(",") else { throw DecodeError.malformed }
        var args: [OSCArgument] = []
        for tag in tags.dropFirst() {
            switch tag {
            case "i": args.append(.int(Int32(bitPattern: try data.readUInt32(at: &cursor))))
            case "f": args.append(.float(Float(bitPattern: try data.readUInt32(at: &cursor))))
            case "s": args.append(.string(try data.readOSCString(at: &cursor)))
            case "T", "F", "N", "I": continue
            default: throw DecodeError.malformed
            }
        }
        return OSCMessage(address, args)
    }

    /// Parses a human readable argument list such as `1 2.5 "go"` into OSC arguments.
    public static func parseArguments(_ text: String) -> [OSCArgument] {
        var result: [OSCArgument] = []
        var token = ""
        var inQuotes = false
        var quoted = false
        func flush() {
            defer { token = ""; quoted = false }
            if quoted { result.append(.string(token)); return }
            guard !token.isEmpty else { return }
            if let i = Int32(token) { result.append(.int(i)) }
            else if let f = Float(token) { result.append(.float(f)) }
            else { result.append(.string(token)) }
        }
        for ch in text {
            if ch == "\"" { inQuotes.toggle(); quoted = true; continue }
            if ch.isWhitespace && !inQuotes { flush(); continue }
            token.append(ch)
        }
        flush()
        return result
    }
}

// MARK: - Data helpers

extension Data {
    mutating func appendOSCString(_ s: String) {
        append(contentsOf: Array(s.utf8))
        let pad = 4 - (s.utf8.count % 4)
        append(contentsOf: [UInt8](repeating: 0, count: pad))
    }

    mutating func appendBigEndian(_ v: UInt32) {
        append(contentsOf: [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)])
    }

    func readUInt32(at cursor: inout Index) throws -> UInt32 {
        guard distance(from: cursor, to: endIndex) >= 4 else { throw OSCMessage.DecodeError.malformed }
        var v: UInt32 = 0
        for i in 0..<4 { v = v << 8 | UInt32(self[cursor + i]) }
        cursor += 4
        return v
    }

    func readOSCString(at cursor: inout Index) throws -> String {
        guard let end = self[cursor...].firstIndex(of: 0) else { throw OSCMessage.DecodeError.malformed }
        let s = String(decoding: self[cursor..<end], as: UTF8.self)
        let len = end - cursor
        cursor += len + (4 - len % 4)
        guard cursor <= endIndex else { throw OSCMessage.DecodeError.malformed }
        return s
    }
}
