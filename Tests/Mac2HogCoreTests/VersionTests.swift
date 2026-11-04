import XCTest
@testable import Mac2HogCore

final class VersionTests: XCTestCase {
    func testVersionIsSemVerAndMatchesVersionFile() throws {
        let parts = Mac2HogVersion.current.split(separator: ".")
        XCTAssertEqual(parts.count, 3)
        XCTAssertTrue(parts.allSatisfy { Int($0) != nil })
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = try String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8)
        XCTAssertEqual(file.trimmingCharacters(in: .whitespacesAndNewlines), Mac2HogVersion.current)
        let plist = try String(contentsOf: root.appendingPathComponent("Resources/Info.plist"), encoding: .utf8)
        XCTAssertTrue(plist.contains("<string>\(Mac2HogVersion.current)</string>"), "Info.plist version out of date")
    }
}
