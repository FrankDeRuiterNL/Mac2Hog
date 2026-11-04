import Foundation

/// The kind of playback object on a Hog 4 console. Raw values match the OSC type index
/// used in `/hog/playback/<action>/<type>`.
public enum HogObjectKind: Int, Codable, CaseIterable, Sendable, Identifiable {
    case cuelist = 0
    case scene = 1
    case macro = 2

    public var id: Int { rawValue }
    public var displayName: String {
        switch self {
        case .cuelist: return "Cuelist"
        case .scene: return "Scene"
        case .macro: return "Macro"
        }
    }
}

public struct HogCue: Codable, Hashable, Sendable, Identifiable {
    public var number: String
    public var name: String
    public var id: String { number }
    public init(number: String, name: String) { self.number = number; self.name = name }
}

/// A cuelist, scene or macro from an imported show.
public struct HogObject: Codable, Hashable, Sendable, Identifiable {
    public var kind: HogObjectKind
    public var number: String
    public var name: String
    public var cues: [HogCue]

    public var id: String { "\(kind.rawValue):\(number)" }
    public var label: String { name.isEmpty ? "\(kind.displayName) \(number)" : "\(kind.displayName) \(number) – \(name)" }

    public init(kind: HogObjectKind, number: String, name: String, cues: [HogCue] = []) {
        self.kind = kind
        self.number = number
        self.name = name
        self.cues = cues
    }
}

/// Library of show objects imported from a Hog 4 show export.
public struct HogShow: Codable, Hashable, Sendable {
    public var name: String
    public var sourcePath: String?
    public var objects: [HogObject]

    public init(name: String, sourcePath: String? = nil, objects: [HogObject] = []) {
        self.name = name
        self.sourcePath = sourcePath
        self.objects = objects
    }

    public func objects(of kind: HogObjectKind) -> [HogObject] {
        objects.filter { $0.kind == kind }.sorted { $0.number.localizedStandardCompare($1.number) == .orderedAscending }
    }

    public func object(kind: HogObjectKind, number: String) -> HogObject? {
        objects.first { $0.kind == kind && $0.number == number }
    }

    public var isEmpty: Bool { objects.isEmpty }
}
