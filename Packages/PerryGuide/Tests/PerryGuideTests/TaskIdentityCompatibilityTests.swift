import XCTest
@testable import PerryGuide

final class TaskIdentityCompatibilityTests: XCTestCase {
    func testTaskIDKeepsLegacyRawStringJSONEncoding() throws {
        let legacyJSON = Data("\"legacy-task-42\"".utf8)
        let encoded = try JSONEncoder().encode(TaskID(rawValue: "legacy-task-42"))

        XCTAssertEqual(encoded, legacyJSON)
        XCTAssertEqual(try JSONDecoder().decode(TaskID.self, from: legacyJSON).rawValue, "legacy-task-42")
    }

    func testTaskIDDecoderRejectsEmptyRawString() {
        let emptyJSON = Data("\"\"".utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(TaskID.self, from: emptyJSON))
    }
}
