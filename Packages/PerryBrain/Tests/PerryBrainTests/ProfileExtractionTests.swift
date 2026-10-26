import XCTest
@testable import PerryBrain

final class ProfileExtractionTests: XCTestCase {
    func testDecodesTheFixedSchema() throws {
        let facts = try ProfileExtraction.decode(#"{"work":"Product designer","apps":["Figma","Notion"],"learningGoal":"Spanish"}"#)
        XCTAssertEqual(facts, ProfileFacts(work: "Product designer", apps: ["Figma", "Notion"], learningGoal: "Spanish"))
    }

    func testDecodesInsideACodeFenceAndDropsBlanks() throws {
        let text = """
        Here you go:
        ```json
        {"work": " ", "apps": ["Xcode", ""], "learningGoal": null}
        ```
        """
        XCTAssertEqual(try ProfileExtraction.decode(text), ProfileFacts(work: nil, apps: ["Xcode"], learningGoal: nil))
    }

    func testRejectsProse() {
        XCTAssertThrowsError(try ProfileExtraction.decode("The user is a designer."))
    }

    func testThePromptCarriesEveryAnswerAndTheSchemaOnly() {
        let prompt = ProfileExtraction.prompt(answers: ["I design apps", "Figma and Notion", "Spanish"])
        for answer in ["I design apps", "Figma and Notion", "Spanish"] { XCTAssertTrue(prompt.contains(answer)) }
        XCTAssertTrue(prompt.contains(ProfileExtraction.schema))
        XCTAssertTrue(ProfileExtraction.prompt(answers: [nil, "Xcode", nil]).contains("(skipped)"))
    }

    func testTheReactionPromptAsksForTwelveWordsAboutTheAnswer() {
        let prompt = ProfileExtraction.reactionPrompt(question: "What do you do?", answer: "I teach chemistry")
        XCTAssertTrue(prompt.contains("I teach chemistry"))
        XCTAssertTrue(prompt.contains("8 words"))
        XCTAssertEqual(ProfileExtraction.trimReaction("\"Chemistry teacher, nice. Lots of labs to plan, I bet.\"\n"), "Chemistry teacher, nice. Lots of labs to plan, I bet.")
        XCTAssertNil(ProfileExtraction.trimReaction(Array(repeating: "word", count: 20).joined(separator: " ")))
    }
}
