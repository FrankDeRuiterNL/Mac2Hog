import XCTest
@testable import Mac2HogCore

final class OSCAndHogTests: XCTestCase {
    func testOSCEncodingMatchesSpec() {
        let msg = OSCMessage("/hog/playback/go/0", [.float(1)])
        let bytes = [UInt8](msg.encoded())
        // "/hog/playback/go/0" is 18 chars → padded to 20; ",f" → 4; float 1.0 = 3F800000
        XCTAssertEqual(bytes.count, 28)
        XCTAssertEqual(Array(bytes[20..<24]), [44, 102, 0, 0])
        XCTAssertEqual(Array(bytes[24..<28]), [0x3F, 0x80, 0, 0])
        XCTAssertEqual(try OSCMessage.decode(msg.encoded()), msg)
    }

    func testRoundTripMixedArgs() throws {
        let msg = OSCMessage("/a", [.int(-5), .string("hello"), .float(2.5)])
        XCTAssertEqual(try OSCMessage.decode(msg.encoded()), msg)
        XCTAssertEqual(OSCMessage.parseArguments("1 2.5 \"go now\" x"), [.int(1), .float(2.5), .string("go now"), .string("x")])
    }

    func testHogMapping() {
        let mapper = HogOSCMapper()
        XCTAssertEqual(mapper.messages(for: .go(.cuelist, "3")), [OSCMessage("/hog/playback/go/0", [.float(3)])])
        XCTAssertEqual(mapper.messages(for: .go(.scene, "2")), [OSCMessage("/hog/playback/go/1", [.float(2)])])
        XCTAssertEqual(mapper.messages(for: .go(.macro, "7")), [OSCMessage("/hog/playback/go/2", [.float(7)])])
        XCTAssertEqual(mapper.messages(for: HogCommand(action: .release, objectKind: .cuelist, objectNumber: "4")),
                       [OSCMessage("/hog/playback/release/0", [.float(4)])])
        XCTAssertEqual(mapper.messages(for: HogCommand(action: .resume, objectKind: .cuelist, objectNumber: "4")),
                       [OSCMessage("/hog/playback/resume/0", [.float(4)])])

        let gotoCmd = HogCommand(action: .gotoCue, objectNumber: "1", cueNumber: "10")
        XCTAssertEqual(mapper.messages(for: gotoCmd), [OSCMessage("/hog/playback/go/0", [.string("1.10")])])
        var cfg = HogOSCConfiguration()
        cfg.gotoStyle = .inAddress
        XCTAssertEqual(HogOSCMapper(configuration: cfg).messages(for: gotoCmd), [OSCMessage("/hog/playback/go/0/1.10")])
        cfg.gotoStyle = .twoArguments
        XCTAssertEqual(HogOSCMapper(configuration: cfg).messages(for: gotoCmd), [OSCMessage("/hog/playback/go/0", [.float(1), .float(10)])])
        cfg.gotoStyle = .floatArgument
        XCTAssertEqual(HogOSCMapper(configuration: cfg).messages(for: gotoCmd), [OSCMessage("/hog/playback/go/0", [.float(1.1)])])
        let old = try! JSONDecoder().decode(HogOSCConfiguration.self, from: Data(#"{"addressPrefix":"/hog","numberFormat":"float","gotoFormat":"float","sendKeyRelease":true}"#.utf8))
        XCTAssertEqual(old.gotoStyle, .stringArgument)

        XCTAssertEqual(mapper.messages(for: HogCommand(action: .masterGo, master: 5)),
                       [OSCMessage("/hog/hardware/go/5", [.int(1)]), OSCMessage("/hog/hardware/go/5", [.int(0)])])
        XCTAssertEqual(mapper.messages(for: HogCommand(action: .masterFader, master: 2, level: 50)),
                       [OSCMessage("/hog/hardware/fader/2", [.int(128)])])
        XCTAssertEqual(mapper.messages(for: HogCommand(action: .custom, customAddress: "/hog/hardware/h1", customArguments: "1")),
                       [OSCMessage("/hog/hardware/h1", [.int(1)])])
    }

    func testUDPLoopback() throws {
        let listener = OSCListener(port: 57_123)
        let exp = expectation(description: "received")
        try listener.start { msg in if msg.address == "/hog/playback/go/0" { exp.fulfill() } }
        let sender = try OSCSender(host: "127.0.0.1", port: 57_123)
        try sender.send(OSCMessage("/hog/playback/go/0", [.float(1)]))
        wait(for: [exp], timeout: 2)
        listener.stop()
    }

    func testXMLShowImport() throws {
        let xml = """
        <?xml version="1.0"?>
        <Show name="Demo">
          <Cuelists>
            <Cuelist number="1" name="Intro Wash">
              <Cue number="1" name="Blue"/>
              <Cue number="2" name="Red"/>
            </Cuelist>
            <Cuelist><Number>2</Number><Name>Snare Flash</Name></Cuelist>
          </Cuelists>
          <Scenes><Scene index="5" name="Blackout"/></Scenes>
          <Macros><Macro num="3"><name>Strobe</name></Macro></Macros>
        </Show>
        """
        let show = try ShowfileImporter.importShow(data: Data(xml.utf8), fileExtension: "xml", name: "Demo")
        XCTAssertEqual(show.objects(of: .cuelist).map(\.name), ["Intro Wash", "Snare Flash"])
        XCTAssertEqual(show.object(kind: .cuelist, number: "1")?.cues.map(\.name), ["Blue", "Red"])
        XCTAssertEqual(show.object(kind: .scene, number: "5")?.name, "Blackout")
        XCTAssertEqual(show.object(kind: .macro, number: "3")?.name, "Strobe")
    }

    func testCSVImportAndBinaryRejection() throws {
        let csv = "type,number,name\ncuelist,1,Wash\nCuelist,1,Wash,2,Chorus look\nscene,3,Strobe\nmacro,10,Reset\n"
        let show = try ShowfileImporter.importShow(data: Data(csv.utf8), fileExtension: "csv", name: "x")
        XCTAssertEqual(show.objects.count, 3)
        XCTAssertEqual(show.object(kind: .cuelist, number: "1")?.cues.first?.name, "Chorus look")

        let binary = Data((0..<2000).map { UInt8(truncatingIfNeeded: $0 * 7919) })
        XCTAssertThrowsError(try ShowfileImporter.importShow(data: binary, fileExtension: "shw", name: "x")) {
            XCTAssertEqual($0 as? ShowfileImporter.ImportError, .nativeShowfile)
        }
    }
}

final class HogNumberTests: XCTestCase {
    func testStepWithoutShowfile() {
        XCTAssertEqual(HogNumber.step("1", by: 1), "2")
        XCTAssertEqual(HogNumber.step("1", by: -1), "1")
        XCTAssertEqual(HogNumber.step("2.5", by: 1), "3")
        XCTAssertEqual(HogNumber.step("2.5", by: -1), "2")
        XCTAssertEqual(HogNumber.step("", by: 1), "1")
    }

    func testStepThroughExistingNumbers() {
        let cues = ["1", "2", "2.5", "10"]
        XCTAssertEqual(HogNumber.step("2", by: 1, existing: cues), "2.5")
        XCTAssertEqual(HogNumber.step("2.5", by: 1, existing: cues), "10")
        XCTAssertEqual(HogNumber.step("10", by: 1, existing: cues), "10")
        XCTAssertEqual(HogNumber.step("10", by: -1, existing: cues), "2.5")
        XCTAssertEqual(HogNumber.step("1", by: -1, existing: cues), "1")
        XCTAssertEqual(HogNumber.step("5", by: 1, existing: cues), "10")
    }
}
