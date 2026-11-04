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

/// How a "go to cue" is encoded. The Hog 4 manual only documents the payload as "cuelist #.cue #",
/// so the variants below can be tried from Settings › OSC › Goto test.
public enum GotoStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    /// `/hog/playback/go/0 "1.2"` – one string argument.
    case stringArgument
    /// `/hog/playback/go/0/1.2` – list.cue in the address, no arguments.
    case inAddress
    /// `/hog/playback/go/0 1.2` – one float argument (ambiguous with decimal cuelist numbers).
    case floatArgument
    /// `/hog/playback/go/0 1 2` – list and cue as two float arguments.
    case twoArguments

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .stringArgument: return "String argument  \"list.cue\""
        case .inAddress: return "In the address  …/go/0/list.cue"
        case .floatArgument: return "Float argument  list.cue"
        case .twoArguments: return "Two arguments  list cue"
        }
    }
}

public struct HogOSCConfiguration: Codable, Hashable, Sendable {
    /// Root of all Hog OSC addresses, normally "/hog".
    public var addressPrefix: String = "/hog"
    public var numberFormat: OSCNumberFormat = .float
    /// Legacy setting (before `gotoStyle`); kept so old settings decode.
    public var gotoFormat: OSCNumberFormat = .string
    /// How "Goto cue" commands are encoded.
    public var gotoStyle: GotoStyle = .stringArgument
    /// Hardware keys are sent as press (1) followed by release (0).
    public var sendKeyRelease: Bool = true

    public init() {}

    private enum CodingKeys: String, CodingKey { case addressPrefix, numberFormat, gotoFormat, gotoStyle, sendKeyRelease }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        addressPrefix = (try? c.decode(String.self, forKey: .addressPrefix)) ?? "/hog"
        numberFormat = (try? c.decode(OSCNumberFormat.self, forKey: .numberFormat)) ?? .float
        gotoFormat = (try? c.decode(OSCNumberFormat.self, forKey: .gotoFormat)) ?? .string
        // The old float default never fired a specific cue, so older settings move to the string style.
        gotoStyle = (try? c.decode(GotoStyle.self, forKey: .gotoStyle)) ?? .stringArgument
        sendKeyRelease = (try? c.decode(Bool.self, forKey: .sendKeyRelease)) ?? true
    }
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

    /// A "go to cue" message in the given style.
    public func gotoMessage(list: String, cue: String, type: Int = 0, style: GotoStyle) -> OSCMessage {
        let l = list.trimmingCharacters(in: .whitespaces), c = cue.trimmingCharacters(in: .whitespaces)
        let base = "\(prefix)/playback/go/\(type)"
        switch style {
        case .stringArgument: return OSCMessage(base, [.string("\(l).\(c)")])
        case .inAddress: return OSCMessage("\(base)/\(l).\(c)")
        case .floatArgument: return OSCMessage(base, [.float(Float("\(l).\(c)") ?? 0)])
        case .twoArguments: return OSCMessage(base, [number(l, format: .float), number(c, format: .float)])
        }
    }

    public func messages(for command: HogCommand) -> [OSCMessage] {
        let p = prefix
        let type = command.objectKind.rawValue
        switch command.action {
        case .go:
            return [OSCMessage("\(p)/playback/go/\(type)", [number(command.objectNumber, format: configuration.numberFormat)])]
        case .gotoCue:
            return [gotoMessage(list: command.objectNumber, cue: command.cueNumber, type: type, style: configuration.gotoStyle)]
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
