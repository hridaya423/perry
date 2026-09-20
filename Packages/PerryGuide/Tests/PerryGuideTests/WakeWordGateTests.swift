import XCTest
@testable import PerryGuide

final class WakeWordGateTests: XCTestCase {
    func testDisabledByDefaultNeverMatches() {
        let gate = WakeWordGate()
        XCTAssertFalse(gate.enabled)
        XCTAssertNil(gate.match(inTranscript: "hey perry rename the files"))
    }

    func testEnabledGateExtractsCommandText() {
        let gate = WakeWordGate(enabled: true)
        XCTAssertEqual(gate.match(inTranscript: "Hey Perry, rename the files"), "rename the files")
        XCTAssertEqual(gate.match(inTranscript: "HEY PERRY RENAME THE FILES"), "rename the files")
    }

    func testBarePhraseMatchesWithNoCommand() {
        let gate = WakeWordGate(enabled: true)
        XCTAssertEqual(gate.match(inTranscript: "hey perry"), "")
    }

    func testNonMatchingTranscriptsReturnNil() {
        let gate = WakeWordGate(enabled: true)
        XCTAssertNil(gate.match(inTranscript: "what's the weather"))
        XCTAssertNil(gate.match(inTranscript: "rename files hey perry"))
    }

    func testNormalizationStripsPunctuation() {
        XCTAssertEqual(WakeWordGate.normalized("Hey, Perry! It's me."), "hey perry it s me")
    }
}
