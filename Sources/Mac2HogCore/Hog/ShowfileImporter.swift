import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Imports cuelists, scenes and macros from a Hog 4 show.
///
/// Supported inputs:
/// * **Hog 4 XML export** (`.xml`) – created on the console from the Cuelist / Scene / Macro
///   directory (Export) or Show export. The parser is schema tolerant: any element whose name
///   contains `cuelist`, `scene` or `macro` becomes an object, and its `cue` children become cues.
///   Numbers / names are read from attributes, simple child elements, or a child `<DirectoryItem>`
///   (the Hog 4 OS v5 `xml_show` schema).
/// * **CSV** (`.csv`, `.txt`) – `type,number,name[,cue number,cue name]`.
/// * **Mac2Hog library** (`.json`) – a previously saved `HogShow`.
/// * **Native show files** (`.shw`, `.hog4`) – these are a proprietary binary database; we
///   detect embedded XML when present, otherwise report how to export the data.
public enum ShowfileImporter {
    public enum ImportError: Error, LocalizedError, Equatable {
        case unreadable
        case nativeShowfile
        case noObjects

        public var errorDescription: String? {
            switch self {
            case .unreadable:
                return "The file could not be read."
            case .nativeShowfile:
                return "This is a native Hog binary show database, which can't be read outside Hog OS. " +
                    "On the console (or Hog PC) open the Cuelist / Scene / Macro directory, select the items " +
                    "and choose Export to save them as XML, then import that XML file here."
            case .noObjects:
                return "No cuelists, scenes or macros were found in this file."
            }
        }
    }

    public static func importShow(from url: URL) throws -> HogShow {
        guard let data = try? Data(contentsOf: url) else { throw ImportError.unreadable }
        let name = url.deletingPathExtension().lastPathComponent
        var show = try importShow(data: data, fileExtension: url.pathExtension.lowercased(), name: name)
        show.sourcePath = url.path
        return show
    }

    public static func importShow(data: Data, fileExtension ext: String, name: String) throws -> HogShow {
        let objects: [HogObject]
        switch ext {
        case "json":
            if let show = try? JSONDecoder().decode(HogShow.self, from: data) { return show }
            throw ImportError.noObjects
        case "csv", "txt", "tsv":
            objects = parseCSV(String(decoding: data, as: UTF8.self))
        case "xml":
            objects = parseXML(data)
        default:
            if let xmlStart = data.range(of: Data("<?xml".utf8)) {
                objects = parseXML(data[xmlStart.lowerBound...])
            } else if looksLikeText(data) {
                let text = String(decoding: data, as: UTF8.self)
                objects = text.contains("<") ? parseXML(data) : parseCSV(text)
            } else {
                throw ImportError.nativeShowfile
            }
        }
        guard !objects.isEmpty else { throw ImportError.noObjects }
        return HogShow(name: name, objects: merge(objects))
    }

    static func looksLikeText(_ data: Data) -> Bool {
        let sample = data.prefix(4096)
        guard !sample.isEmpty else { return false }
        let printable = sample.filter { $0 == 9 || $0 == 10 || $0 == 13 || ($0 >= 32 && $0 < 127) || $0 >= 0xC0 }.count
        return Double(printable) / Double(sample.count) > 0.95
    }

    /// Combines duplicates (same kind+number) keeping the richest information.
    static func merge(_ objects: [HogObject]) -> [HogObject] {
        var order: [String] = []
        var map: [String: HogObject] = [:]
        for obj in objects {
            if var existing = map[obj.id] {
                if existing.name.isEmpty { existing.name = obj.name }
                for cue in obj.cues where !existing.cues.contains(where: { $0.number == cue.number }) {
                    existing.cues.append(cue)
                }
                map[obj.id] = existing
            } else {
                order.append(obj.id)
                map[obj.id] = obj
            }
        }
        return order.compactMap { map[$0] }
    }

    // MARK: CSV

    static func parseCSV(_ text: String) -> [HogObject] {
        var objects: [HogObject] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let separator: Character = line.contains("\t") ? "\t" : (line.contains(";") && !line.contains(",") ? ";" : ",")
            let cols = splitCSV(line, separator: separator)
            guard cols.count >= 2, let kind = kind(from: cols[0]) else { continue }
            let number = normalizeNumber(cols[1])
            guard !number.isEmpty else { continue }
            var obj = HogObject(kind: kind, number: number, name: cols.count > 2 ? cols[2] : "")
            if cols.count > 3, !cols[3].isEmpty {
                obj.cues.append(HogCue(number: normalizeNumber(cols[3]), name: cols.count > 4 ? cols[4] : ""))
            }
            objects.append(obj)
        }
        return objects
    }

    static func splitCSV(_ line: String, separator: Character) -> [String] {
        var cols: [String] = []
        var current = ""
        var quoted = false
        for ch in line {
            if ch == "\"" { quoted.toggle(); continue }
            if ch == separator && !quoted { cols.append(current.trimmingCharacters(in: .whitespaces)); current = ""; continue }
            current.append(ch)
        }
        cols.append(current.trimmingCharacters(in: .whitespaces))
        return cols
    }

    static func kind(from text: String) -> HogObjectKind? {
        let t = text.lowercased()
        if t.contains("cuelist") || t.contains("cue list") || t == "list" || t == "cl" { return .cuelist }
        if t.contains("scene") || t == "sc" { return .scene }
        if t.contains("macro") || t == "mc" || t == "mac" { return .macro }
        return nil
    }

    static func normalizeNumber(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = Double(t), d == d.rounded(), !t.contains(".") || t.hasSuffix(".0") { return String(Int(d)) }
        return t
    }

    // MARK: XML

    static func parseXML<D: DataProtocol>(_ data: D) -> [HogObject] {
        let delegate = HogXMLDelegate()
        let parser = XMLParser(data: Data(data))
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.objects
    }
}

private final class HogXMLDelegate: NSObject, XMLParserDelegate {
    private struct Frame {
        var element: String
        var kind: HogObjectKind?
        var isCue: Bool
        var attributes: [String: String]
        var fields: [String: String] = [:]
        var cues: [HogCue] = []
        var text = ""
    }

    var objects: [HogObject] = []
    private var stack: [Frame] = []

    static let numberKeys = ["number", "num", "index", "no", "id", "cuelistnumber", "scenenumber", "macronumber"]
    // A cue's own number. (`cuelistNumber` on a Hog 4 <Cue> is its parent list, not the cue.)
    static let cueNumberKeys = ["number", "num", "index", "no", "id", "cuenumber"]
    static let nameKeys = ["name", "title", "label", "cuelistname", "scenename", "macroname", "cuename"]

    private static func classify(_ element: String) -> (HogObjectKind?, Bool) {
        let e = element.lowercased()
        // Containers such as <Cuelists>, <Cues>, <SceneDirectory> and settings blocks such as
        // <CuelistOptions> / <SceneOptions> are not objects themselves.
        if (e.hasSuffix("s") && !e.hasSuffix("ss")) || e.hasSuffix("directory") || e.hasSuffix("folder")
            || e.contains("option") || e.contains("pref") || e.contains("descriptor") {
            return (nil, false)
        }
        if e.contains("cuelist") || e == "list" { return (.cuelist, false) }
        if e.contains("scene") { return (.scene, false) }
        if e.contains("macro") { return (.macro, false) }
        if e == "cue" || e.hasSuffix(":cue") { return (nil, true) }
        return (nil, false)
    }

    private static func lookup(_ keys: [String], in dict: [String: String]) -> String? {
        let lowered = Dictionary(dict.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        for k in keys { if let v = lowered[k], !v.isEmpty { return v } }
        return nil
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        // Hog 4 XML exports keep an object's number and name in a child element:
        //   <Cuelist …><DirectoryItem number="1" name="List 1"/> … <Cue …><DirectoryItem number="2" name="Cue 2"/>
        if elementName.lowercased().hasSuffix("directoryitem"), let parent = stack.indices.last,
           stack[parent].kind != nil || stack[parent].isCue {
            for (key, value) in attributeDict {
                let k = key.lowercased()
                if (k == "number" || k == "name"), stack[parent].fields[k] == nil { stack[parent].fields[k] = value }
            }
        }
        let (kind, isCue) = Self.classify(elementName)
        stack.append(Frame(element: elementName, kind: kind, isCue: isCue, attributes: attributeDict))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard let frame = stack.popLast() else { return }
        let text = frame.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Fields from child elements (e.g. <DirectoryItem number=…>) take precedence over the element's own attributes.
        let info = frame.attributes.merging(frame.fields) { _, field in field }

        if frame.isCue {
            if let number = Self.lookup(Self.cueNumberKeys, in: info), let idx = ownerIndex() {
                stack[idx].cues.append(HogCue(number: ShowfileImporter.normalizeNumber(number),
                                              name: Self.lookup(Self.nameKeys, in: info) ?? ""))
            }
            return
        }
        if let kind = frame.kind {
            if let number = Self.lookup(Self.numberKeys, in: info) {
                objects.append(HogObject(kind: kind, number: ShowfileImporter.normalizeNumber(number),
                                         name: Self.lookup(Self.nameKeys, in: info) ?? "", cues: frame.cues))
            }
            return
        }
        // Simple child element like <Name>Intro</Name> or <Number>3</Number>: store on parent.
        if !text.isEmpty, !stack.isEmpty, frame.attributes.isEmpty || frame.attributes.keys.allSatisfy({ $0.lowercased() == "type" }) {
            let key = elementName.lowercased()
            if stack[stack.count - 1].fields[key] == nil { stack[stack.count - 1].fields[key] = text }
        }
    }

    /// Nearest enclosing cuelist/scene/macro frame.
    private func ownerIndex() -> Int? {
        stack.lastIndex { $0.kind != nil }
    }
}
