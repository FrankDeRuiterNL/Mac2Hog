import Foundation

/// What the console should do when a trigger fires.
public enum HogAction: String, Codable, CaseIterable, Sendable, Identifiable {
    // Playback object actions: /hog/playback/<action>/<type> <number>
    case go, gotoCue, halt, resume, release
    // Physical master actions: /hog/hardware/<action>/<master>
    case masterGo, masterPause, masterBack, masterFader
    // Main (centre) playback controls
    case mainGo, mainHalt, mainBack
    // Arbitrary OSC
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .go: return "Go"
        case .gotoCue: return "Goto Cue"
        case .halt: return "Halt"
        case .resume: return "Resume"
        case .release: return "Release"
        case .masterGo: return "Master Go"
        case .masterPause: return "Master Pause"
        case .masterBack: return "Master Back"
        case .masterFader: return "Master Fader Level"
        case .mainGo: return "Main Go"
        case .mainHalt: return "Main Halt"
        case .mainBack: return "Main Back"
        case .custom: return "Custom OSC"
        }
    }

    /// Whether the action addresses a cuelist/scene/macro object.
    public var usesObject: Bool { [.go, .gotoCue, .halt, .resume, .release].contains(self) }
    public var usesMaster: Bool { [.masterGo, .masterPause, .masterBack, .masterFader].contains(self) }

    /// Actions valid for an object kind (scenes/macros cannot resume or goto cues).
    public static func actions(for kind: HogObjectKind) -> [HogAction] {
        switch kind {
        case .cuelist: return [.go, .gotoCue, .halt, .resume, .release]
        case .scene, .macro: return [.go, .halt, .release]
        }
    }
}

/// A single console command attached to a trigger. Converted into one or more OSC messages
/// by `HogOSCMapper` using the current OSC settings.
public struct HogCommand: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var action: HogAction
    public var objectKind: HogObjectKind
    /// Cuelist / scene / macro number (e.g. "12" or "1.5").
    public var objectNumber: String
    /// Cue number for `gotoCue`.
    public var cueNumber: String
    /// Physical master number for master actions.
    public var master: Int
    /// Fader level 0...100 % for `masterFader`.
    public var level: Double
    /// Custom OSC address and arguments for `custom`.
    public var customAddress: String
    public var customArguments: String
    /// Optional label shown in the UI (e.g. the cuelist name from the showfile).
    public var label: String

    public init(id: UUID = UUID(), action: HogAction = .go, objectKind: HogObjectKind = .cuelist,
                objectNumber: String = "1", cueNumber: String = "1", master: Int = 1, level: Double = 100,
                customAddress: String = "/hog/hardware/maingo", customArguments: String = "", label: String = "") {
        self.id = id
        self.action = action
        self.objectKind = objectKind
        self.objectNumber = objectNumber
        self.cueNumber = cueNumber
        self.master = master
        self.level = level
        self.customAddress = customAddress
        self.customArguments = customArguments
        self.label = label
    }

    public static func go(_ kind: HogObjectKind, _ number: String, label: String = "") -> HogCommand {
        HogCommand(action: .go, objectKind: kind, objectNumber: number, label: label)
    }

    public var summary: String {
        switch action {
        case .go, .halt, .resume, .release:
            let name = label.isEmpty ? "" : " (\(label))"
            return "\(action.displayName) \(objectKind.displayName) \(objectNumber)\(name)"
        case .gotoCue:
            return "Goto \(objectKind.displayName) \(objectNumber) cue \(cueNumber)" + (label.isEmpty ? "" : " (\(label))")
        case .masterGo, .masterPause, .masterBack:
            return "\(action.displayName) \(master)"
        case .masterFader:
            return "Master \(master) fader \(Int(level))%"
        case .mainGo, .mainHalt, .mainBack:
            return action.displayName
        case .custom:
            return customArguments.isEmpty ? customAddress : "\(customAddress) \(customArguments)"
        }
    }
}
