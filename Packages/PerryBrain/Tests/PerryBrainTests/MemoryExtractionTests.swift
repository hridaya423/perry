import XCTest
@testable import PerryBrain

final class MemoryExtractionTests: XCTestCase {
    func testDecodesFactsAndDropsKnownSecretAndDuplicateOnes() {
        let reply = """
        Sure. {"facts": [
          {"text": "Manager is Sam", "kind": "person", "subject": "Manager", "days": null},
          {"text": "Works at Acme", "kind": "profile", "subject": "employer"},
          {"text": "Password is hunter2", "kind": "profile", "subject": "password"},
          {"text": "manager is sam", "kind": "person", "subject": "manager"},
          {"text": "Launch on Friday", "kind": "event", "subject": "launch", "days": 900}
        ]}
        """
        let facts = MemoryExtraction.decode(reply, known: ["Works at Acme"])
        XCTAssertEqual(facts.map(\.text), ["Manager is Sam", "Launch on Friday"])
        XCTAssertEqual(facts.first?.subject, "manager")
        XCTAssertEqual(facts.last?.days, 365)
    }

    func testEmptyAndMalformedRepliesKeepNothing() {
        XCTAssertTrue(MemoryExtraction.decode(#"{"facts": []}"#, known: []).isEmpty)
        XCTAssertTrue(MemoryExtraction.decode("I could not find anything.", known: []).isEmpty)
    }

    func testSecretsAreRecognised() {
        XCTAssertTrue(MemoryExtraction.looksSecret("Their key is sk-proj-abcdefghijklmnop"))
        XCTAssertTrue(MemoryExtraction.looksSecret("Card 4242 4242 4242 4242"))
        XCTAssertFalse(MemoryExtraction.looksSecret("Prefers short answers"))
    }

    func testAtMostThreeFactsPerTurn() {
        let rows = (1...5).map { #"{"text": "Fact \#($0)", "kind": "profile", "subject": "s\#($0)"}"# }.joined(separator: ",")
        XCTAssertEqual(MemoryExtraction.decode(#"{"facts": [\#(rows)]}"#, known: []).count, 3)
    }
}
