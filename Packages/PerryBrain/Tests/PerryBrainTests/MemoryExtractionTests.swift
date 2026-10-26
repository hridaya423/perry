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

final class InterviewPolicyTests: XCTestCase {
    func testDigOnlyAfterRichAnswersWithinBudget() {
        XCTAssertTrue(InterviewPolicy.shouldDig(answer: "I design onboarding for a fintech startup in Berlin", followUpsAsked: 0, elapsed: 20))
        XCTAssertFalse(InterviewPolicy.shouldDig(answer: "Designer", followUpsAsked: 0, elapsed: 20))
        XCTAssertFalse(InterviewPolicy.shouldDig(answer: nil, followUpsAsked: 0, elapsed: 20))
        XCTAssertFalse(InterviewPolicy.shouldDig(answer: "I design onboarding for a fintech startup in Berlin", followUpsAsked: 2, elapsed: 20))
        XCTAssertFalse(InterviewPolicy.shouldDig(answer: "I design onboarding for a fintech startup in Berlin", followUpsAsked: 0, elapsed: 95))
    }

    func testBackOffAfterTwoShortAnswersOrTheTimeBudget() {
        XCTAssertFalse(InterviewPolicy.shouldBackOff(shortStreak: 1, elapsed: 30))
        XCTAssertTrue(InterviewPolicy.shouldBackOff(shortStreak: 2, elapsed: 30))
        XCTAssertTrue(InterviewPolicy.shouldBackOff(shortStreak: 0, elapsed: 90))
        XCTAssertTrue(InterviewPolicy.isShort("yes"))
        XCTAssertTrue(InterviewPolicy.isShort(nil))
        XCTAssertFalse(InterviewPolicy.isShort("mostly product design"))
    }

    func testFollowUpCleaning() {
        XCTAssertEqual(InterviewPolicy.cleanFollowUp("\"Are you raising money right now?\""), "Are you raising money right now?")
        XCTAssertNil(InterviewPolicy.cleanFollowUp("NONE"))
        XCTAssertNil(InterviewPolicy.cleanFollowUp("That sounds great."))
    }

    func testImportKeepsFactsAndDropsSecrets() {
        let reply = #"{"facts": [{"text": "Works as a product designer", "kind": "profile", "subject": "role"}, {"text": "API key is sk-abcdefghijklmnopqrs", "kind": "profile", "subject": "key"}]}"#
        XCTAssertEqual(MemoryExtraction.decodeImport(reply).map(\.text), ["Works as a product designer"])
    }
}
