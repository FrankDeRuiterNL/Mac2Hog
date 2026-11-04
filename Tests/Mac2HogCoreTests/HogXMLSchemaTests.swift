import XCTest
@testable import Mac2HogCore

/// Hog OS v5 `xml_show` exports keep numbers and names in child <DirectoryItem> elements.
final class HogXMLSchemaTests: XCTestCase {
    static let sample = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Hog xmlns="http://schemav5.hogfour.com/xml_show">
      <Show name="Demo" maj_version="5">
        <Schedule><PlaybackPrefs><CuelistOptions priority="0"/><SceneOptions priority="0"/></PlaybackPrefs></Schedule>
        <Cuelist kindUsageI="41" timecodeCueCount="0">
          <DirectoryItem number="1" name="List 1" XML_COMM_ID="2"><userFieldsMap/></DirectoryItem>
          <CuelistOptions htp="false" priority="0"><MaskingOptions mode="Disabled"/></CuelistOptions>
          <Cue kind="I....T" type="Look" cuelistNumber="1">
            <DirectoryItem number="1" name="Cue 1" XML_COMM_ID="12"/>
            <macros/>
          </Cue>
          <Cue kind="I....T" type="Look" cuelistNumber="1">
            <DirectoryItem number="2.5" name="Chorus" XML_COMM_ID="13"/>
          </Cue>
        </Cuelist>
        <Cuelist><DirectoryItem number="7" name="Strobes"/></Cuelist>
        <Scene><DirectoryItem number="3" name="Blackout"/></Scene>
        <Macro><DirectoryItem number="4" name="Smoke"/></Macro>
        <Group><DirectoryItem number="1" name="All Fixtures"/></Group>
        <ColorPalette><DirectoryItem number="1" name="Open Colour"/></ColorPalette>
      </Show>
    </Hog>
    """

    func testDirectoryItemSchema() throws {
        let show = try ShowfileImporter.importShow(data: Data(Self.sample.utf8), fileExtension: "xml", name: "Demo")
        XCTAssertEqual(show.objects(of: .cuelist).map(\.number), ["1", "7"])
        XCTAssertEqual(show.object(kind: .cuelist, number: "1")?.name, "List 1")
        XCTAssertEqual(show.object(kind: .cuelist, number: "1")?.cues.map(\.number), ["1", "2.5"])
        XCTAssertEqual(show.object(kind: .cuelist, number: "1")?.cues.map(\.name), ["Cue 1", "Chorus"])
        XCTAssertEqual(show.object(kind: .scene, number: "3")?.name, "Blackout")
        XCTAssertEqual(show.object(kind: .macro, number: "4")?.name, "Smoke")
        XCTAssertEqual(show.objects.count, 4, "groups, palettes and option blocks must not become objects")
    }

    /// Optional: MAC2HOG_REAL_EXPORT=/path/to/export.xml swift test --filter HogXMLSchemaTests
    func testRealExportIfProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["MAC2HOG_REAL_EXPORT"] else { throw XCTSkip("no export given") }
        let show = try ShowfileImporter.importShow(from: URL(fileURLWithPath: path))
        for o in show.objects { print("IMPORTED", o.label, "cues:", o.cues.count, o.cues.prefix(3).map { "\($0.number) \($0.name)" }) }
        XCTAssertFalse(show.objects.isEmpty)
    }
}
