import XCTest
import PerryRuntimes
@testable import PerryGuide

final class SpatialAnswerTests: XCTestCase {
    private func observation(
        id: String = "capture-1", processID: Int32? = 42, windowID: Int64? = 7,
        generation: UInt64? = 1, label: String = "Timeline", bundleID: String = "com.example.Editor",
        sensitivity: AXSensitivity = .unknown, screenshot: Data? = nil
    ) -> GuideObservation {
        GuideObservation(
            snapshot: AXSnapshot(appBundleID: bundleID, windowTitle: "Document", elements: [
                AXElement(stableID: "label", role: .staticText, label: label,
                          frame: AXElementFrame(x: -50, y: 20, width: 80, height: 20),
                          isActionable: false, sensitivity: sensitivity),
            ]),
            processID: processID, windowID: windowID, connectionGeneration: generation,
            windowBounds: AXElementFrame(x: -100, y: 0, width: 300, height: 200),
            screenshotData: screenshot, observationID: id
        )
    }

    private let response = #"{"text":"This is the timeline.","references":[{"caption":"Timeline","elementID":"label"}],"followUp":"Would you like a guide?"}"#

    func testConversationIsBoundedByTurnsAndTextBytes() throws {
        let answer = try SpatialAnswer.decode(response, observation: observation())
        var conversation = SpatialConversation()
        for index in 0..<20 { try conversation.append(question: "Question \(index)", answer: answer) }
        XCTAssertEqual(conversation.turns.count, 8)
        XCTAssertEqual(conversation.turns.first?.question, "Question 12")
        let long = try SpatialAnswer.decode("{\"text\":\"\(String(repeating: "a", count: 8_192))\",\"references\":[]}", observation: observation())
        try conversation.append(question: "q", answer: long)
        try conversation.append(question: "q", answer: long)
        XCTAssertEqual(conversation.turns.count, 1)
        XCTAssertThrowsError(try conversation.append(question: String(repeating: "a", count: 8_193), answer: answer))
        XCTAssertEqual(conversation.turns.count, 1)
    }

    func testProviderReceivesQuestionAndReturnsOnlyValidatedAnswer() async throws {
        let response = self.response
        let client = DirectProviderClient(
            configuration: .init(provider: .openAI, model: "fixture"), apiKeyProvider: { "test-key" },
            transport: { request in
                let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
                XCTAssertTrue(body.contains("What is this?"))
                XCTAssertTrue(body.contains("Timeline"))
                XCTAssertTrue(body.contains("image_url"))
                let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": response]]]])
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        )
        let answer = try await RuntimeSpatialAnswerer(client: client).answer(
            question: "What is this?", observation: observation(screenshot: Data([1, 2, 3]))
        )
        XCTAssertEqual(answer.references[0].target, .element(stableID: "label"))
    }

    func testSecureObservationOmitsScreenshotAndSecureLabelsFromProvider() async throws {
        let client = DirectProviderClient(
            configuration: .init(provider: .openAI, model: "fixture"), apiKeyProvider: { "test-key" },
            transport: { request in
                let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
                XCTAssertFalse(body.contains("image_url"))
                XCTAssertFalse(body.contains("SECURE-SENTINEL"))
                let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": #"{"text":"I cannot inspect that field.","references":[]}"#]]]])
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        )
        _ = try await RuntimeSpatialAnswerer(client: client).answer(
            question: "What is this?",
            observation: observation(label: "SECURE-SENTINEL", sensitivity: .secure, screenshot: Data([1, 2, 3]))
        )
    }

    func testProtectedTargetNeverReachesProvider() async throws {
        let client = DirectProviderClient(
            configuration: .init(provider: .openAI, model: "fixture"), apiKeyProvider: { "test-key" },
            transport: { _ in
                XCTFail("protected context must not reach transport")
                throw SpatialAnswerError.invalidResponse
            }
        )
        do {
            _ = try await RuntimeSpatialAnswerer(client: client).answer(
                question: "What is this?", observation: observation(bundleID: "com.agilebits.onepassword-osx")
            )
            XCTFail("expected protectedWindow")
        } catch GuidePlannerError.protectedWindow {}
    }

    func testCancelledProviderResponseIsNotPublished() async throws {
        let client = DirectProviderClient(
            configuration: .init(provider: .openAI, model: "fixture"), apiKeyProvider: { "test-key" },
            transport: { request in
                withUnsafeCurrentTask { $0?.cancel() }
                let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": #"{"text":"Late answer","references":[]}"#]]]])
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        )
        let observation = observation()
        let task = Task { try await RuntimeSpatialAnswerer(client: client).answer(question: "What is this?", observation: observation) }
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
    }

    func testReadOnlyElementCanBeReferencedWithoutBecomingAnAction() throws {
        let answer = try SpatialAnswer.decode(response, observation: observation())
        XCTAssertEqual(answer.text, "This is the timeline.")
        XCTAssertEqual(answer.followUp, "Would you like a guide?")
        XCTAssertEqual(answer.references.count, 1)
        XCTAssertEqual(answer.references[0].target, .element(stableID: "label"))
        XCTAssertEqual(answer.references[0].frame.x, -50)
        XCTAssertEqual(answer.references[0].observationID, "capture-1")
    }

    func testVisualRegionUsesObservedWindowCoordinates() throws {
        let answer = try SpatialAnswer.decode(
            #"{"text":"The toolbar is here.","references":[{"caption":"Toolbar","region":{"x":-100,"y":0,"width":300,"height":20}}]}"#,
            observation: observation()
        )
        XCTAssertEqual(answer.references[0].target, .region)
        XCTAssertEqual(answer.references[0].frame.width, 300)
    }

    func testInvalidReferencesRejectWholeAnswer() {
        let references = [
            #"{"caption":"Missing","elementID":"invented"}"#,
            #"{"caption":"Outside","region":{"x":-101,"y":0,"width":30,"height":20}}"#,
            #"{"caption":"Empty","region":{"x":0,"y":0,"width":0,"height":20}}"#,
            #"{"caption":"Boolean","region":{"x":true,"y":0,"width":30,"height":20}}"#,
            #"{"caption":"Mixed","elementID":"label","region":{"x":0,"y":0,"width":30,"height":20}}"#,
            #"{"caption":"","elementID":"label"}"#,
        ]
        for reference in references {
            let text = "{\"text\":\"Answer\",\"references\":[\(reference)]}"
            XCTAssertThrowsError(try SpatialAnswer.decode(text, observation: observation()), text)
        }
    }

    func testActionPayloadsAndAmbiguousJSONAreRejected() {
        for text in [
            #"{"text":"Answer","references":[],"action":{"click":"label"}}"#,
            #"{"text":"One","text":"Two","references":[]}"#,
            #"Here is the answer: {"text":"Answer","references":[]}"#,
            #"{"text":"Answer","references":[],"followUp":true}"#,
            #"{"text":"Answer"}"#,
        ] {
            XCTAssertThrowsError(try SpatialAnswer.decode(text, observation: observation()))
        }
    }

    func testReferenceCountAndTextBytesAreBounded() throws {
        let reference = #"{"caption":"Timeline","elementID":"label"}"#
        let tooMany = "{\"text\":\"Answer\",\"references\":[\(Array(repeating: reference, count: 4).joined(separator: ","))]}"
        XCTAssertThrowsError(try SpatialAnswer.decode(tooMany, observation: observation()))
        let oversized = "{\"text\":\"\(String(repeating: "é", count: 4_097))\",\"references\":[]}"
        XCTAssertThrowsError(try SpatialAnswer.decode(oversized, observation: observation()))
        let duplicates = "{\"text\":\"Answer\",\"references\":[\(reference),\(reference)]}"
        XCTAssertThrowsError(try SpatialAnswer.decode(duplicates, observation: observation()))
        let noReferences = try SpatialAnswer.decode(#"{"text":"I cannot identify that control.","references":[],"followUp":null}"#, observation: observation())
        XCTAssertTrue(noReferences.references.isEmpty)
        XCTAssertNil(noReferences.followUp)
    }

    func testProtectedWindowsAndSecureElementsAreRejected() {
        XCTAssertThrowsError(try SpatialAnswer.decode(response, observation: observation(bundleID: "com.agilebits.onepassword-osx")))
        XCTAssertThrowsError(try SpatialAnswer.decode(response, observation: observation(sensitivity: .secure)))
        XCTAssertThrowsError(try SpatialAnswer.decode(
            #"{"text":"Here","references":[{"caption":"Input","region":{"x":-50,"y":20,"width":80,"height":20}}]}"#,
            observation: observation(sensitivity: .secure)
        ))
    }

    func testFreshObservationRebindsAnswerAndReferences() throws {
        let baseline = observation()
        let answer = try SpatialAnswer.decode(response, observation: baseline)
        let fresh = try answer.revalidated(from: baseline, to: observation(id: "capture-2"))
        XCTAssertEqual(fresh.observationID, "capture-2")
        XCTAssertEqual(fresh.references[0].observationID, "capture-2")
        XCTAssertEqual(fresh.text, answer.text)
    }

    func testChangedOrMissingIdentityRejectsLateAnswer() throws {
        let baseline = observation()
        let answer = try SpatialAnswer.decode(response, observation: baseline)
        for current in [
            observation(id: "capture-2", processID: 43),
            observation(id: "capture-2", windowID: 8),
            observation(id: "capture-2", generation: 2),
            observation(id: "capture-2", processID: nil),
            observation(id: "capture-2", bundleID: "com.example.Other"),
            observation(id: "capture-2", label: "Other control"),
        ] {
            XCTAssertThrowsError(try answer.revalidated(from: baseline, to: current)) { error in
                XCTAssertEqual(error as? SpatialAnswerError, .staleObservation)
            }
        }
        XCTAssertThrowsError(try answer.revalidated(from: observation(id: "wrong-baseline"), to: observation(id: "capture-2")))
    }
}
