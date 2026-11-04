import Foundation

/// How numeric data is sent to the console. Hog 4 documents the payload as "cuelist #" /
/// "cuelist #.cue #"; most controllers (TouchOSC, Lemur) send floats.
public enum OSCNumberFormat: String, Codable, CaseIterable, Sendable, Identifiable {
    case float, int, string
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .float: return "Float (f)"
        case .int: return "Integer (i)"
        case .string: return "String (s)"
        }
    }
}

public struct HogOSCConfiguration: Codable, Hashable, Sendable {
    /// Root of all Hog OSC addresses, normally "/hog".
    public var addressPrefix: String = "/hog"
    public var numberFormat: OSCNumberFormat = .float
    /// Format for "list.cue" goto payloads. String preserves cue 1.10 vs 1.1.
    public var gotoFormat: OSCNumberFormat = .float
    /// Hardware keys are sent as press (1) followed by release (0).
    public var sendKeyRelease: Bool = true

    public init() {}
}

/// Converts `HogCommand`s into the OSC messages documented in the Hog 4 OS manual
/// (section "OSC Mappings").
public struct HogOSCMapper: Sendable {
    public var configuration: HogOSCConfiguration

    public init(configuration: HogOSCConfiguration = HogOSCConfiguration()) {
        self.configuration = configuration
    }

    private var prefix: String {
        var p = configuration.addressPrefix.trimmingCharacters(in: .whitespaces)
        if p.hasSuffix("/") { p.removeLast() }
        if !p.isEmpty && !p.hasPrefix("/") { p = "/" + p }
        return p
    }

    func number(_ text: String, format: OSCNumberFormat) -> OSCArgument {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        switch format {
        case .string: return .string(trimmed)
        case .int: return .int(Int32(Double(trimmed).map { Int($0) } ?? 0))
        case .float: return .float(Float(trimmed) ?? 0)
        }
    }

    private func keyPress(_ address: String) -> [OSCMessage] {
        var msgs = [OSCMessage(address, [.int(1)])]
        if configuration.sendKeyRelease { msgs.append(OSCMessage(address, [.int(0)])) }
        return msgs
    }

    public func messages(for command: HogCommand) -> [OSCMessage] {
        let p = prefix
        let type = command.objectKind.rawValue
        switch command.action {
        case .go:
            return [OSCMessage("\(p)/playback/go/\(type)", [number(command.objectNumber, format: configuration.numberFormat)])]
        case .gotoCue:
            let payload = "\(command.objectNumber).\(command.cueNumber)"
            return [OSCMessage("\(p)/playback/go/\(type)", [number(payload, format: configuration.gotoFormat)])]
        case .halt:
            return [OSCMessage("\(p)/playback/halt/\(type)", [number(command.objectNumber, format: configuration.numberFormat)])]
        case .resume:
            return [OSCMessage("\(p)/playback/resume/\(type)", [number(command.objectNumber, format: configuration.numberFormat)])]
        case .release:
            return [OSCMessage("\(p)/playback/release/\(type)", [number(command.objectNumber, format: configuration.numberFormat)])]
        case .masterGo:
            return keyPress("\(p)/hardware/go/\(command.master)")
        case .masterPause:
            return keyPress("\(p)/hardware/pause/\(command.master)")
        case .masterBack:
            return keyPress("\(p)/hardware/goback/\(command.master)")
        case .masterFader:
            let value = Int32(max(0, min(255, (command.level / 100 * 255).rounded())))
            return [OSCMessage("\(p)/hardware/fader/\(command.master)", [.int(value)])]
        case .mainGo:
            return keyPress("\(p)/hardware/maingo")
        case .mainHalt:
            return keyPress("\(p)/hardware/mainhalt")
        case .mainBack:
            return keyPress("\(p)/hardware/mainback")
        case .custom:
            let address = command.customAddress.trimmingCharacters(in: .whitespaces)
            guard address.hasPrefix("/") else { return [] }
            return [OSCMessage(address, OSCMessage.parseArguments(command.customArguments))]
        }
    }
}
