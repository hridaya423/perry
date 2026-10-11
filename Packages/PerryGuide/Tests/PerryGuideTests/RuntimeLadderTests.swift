import XCTest
@testable import PerryGuide
import PerryCore
import PerryRuntimes

private actor PromptCapture {
    private(set) var prompts: [String] = []
    func record(_ prompt: String) { prompts.append(prompt) }
}

final class HardwareAndKeysTests: XCTestCase {
    func testKeychainRoundTrip() throws {
        let store = KeychainStore(service: "dev.perry.tests")
        defer { try? store.deleteChecked(account: "test-key") }

        try store.save("secret-one", account: "test-key")
        XCTAssertEqual(try store.readChecked(account: "test-key"), "secret-one")

        try store.save("secret-two", account: "test-key")
        XCTAssertEqual(try store.readChecked(account: "test-key"), "secret-two")

        try store.deleteChecked(account: "test-key")
        XCTAssertNil(try store.readChecked(account: "test-key"))
    }

    func testHardwareProbePassesOnQualifyingMachine() {
        let probe = HardwareProbe()
        let report = probe.evaluate(chipName: "Apple M3 Pro", physicalMemoryBytes: 18 * 1024 * 1024 * 1024)
        XCTAssertTrue(report.passesFloor)
        XCTAssertNil(report.reasonIfBelow)
    }

    func testHardwareProbeFailsUnderMemoryFloorWithSpecifics() {
        let probe = HardwareProbe()
        let report = probe.evaluate(chipName: "Apple M2", physicalMemoryBytes: 8 * 1024 * 1024 * 1024)
        XCTAssertFalse(report.passesFloor)
        XCTAssertEqual(report.reasonIfBelow, "8 GB of unified memory is under the 16 GB floor for usable 4–7B quantized models.")
    }

    func testHardwareProbeFailsOnIntel() {
        let probe = HardwareProbe()
        let report = probe.evaluate(chipName: "Intel Core i9", physicalMemoryBytes: 32 * 1024 * 1024 * 1024)
        XCTAssertFalse(report.passesFloor)
        XCTAssertTrue(report.reasonIfBelow?.contains("Apple silicon") == true)
    }
}

final class RuntimeGuidePlannerTests: XCTestCase {
    private func button(_ id: String, label: String) -> AXElement {
        AXElement(
            stableID: id,
            role: .button,
            label: label,
            frame: AXElementFrame(x: 0, y: 0, width: 80, height: 24),
            isActionable: true
        )
    }

    private func observation() -> GuideObservation {
        GuideObservation(
            snapshot: AXSnapshot(
                appBundleID: "com.apple.finder",
                windowTitle: "Desktop",
                elements: [button("b1", label: "Tags"), button("s1", label: "Share")]
            ),
            windowBounds: AXElementFrame(x: 0, y: 0, width: 800, height: 600)
        )
    }

    private func planner(
        reply: @escaping @Sendable () throws -> String,
        capture: PromptCapture? = nil
    ) -> RuntimeGuidePlanner {
        RuntimeGuidePlanner(complete: { prompt, _ in
            await capture?.record(prompt)
            return try reply()
        })
    }

    func testParsesAStep() async throws {
        let planner = planner(reply: { #"{"step":{"instruction":"click Tags","target":"b1"}}"# })

        let decision = try await planner.nextStep(goal: "tag the file", observation: observation(), context: .empty)

        guard case .step(let step) = decision else {
            return XCTFail("expected step, got \(decision)")
        }
        XCTAssertEqual(step.instruction, "click Tags")
        if case .axElement(let id) = step.target {
            XCTAssertEqual(id, "b1")
        } else {
            XCTFail("expected element target")
        }
    }

    func testScreenContextReachesThePlannerRequest() async throws {
        let capture = PromptCapture()
        let planner = planner(
            reply: { #"{"step":{"instruction":"click Tags","target":"b1"}}"# },
            capture: capture
        )
        let context = GuideContext(
            spatialRegionDescription: "the toolbar area",
            memoryContext: "Prefers archive folders"
        )

        _ = try await planner.nextStep(goal: "tag the file", observation: observation(), context: context)

        let prompts = await capture.prompts
        let sent = try XCTUnwrap(prompts.first)
        XCTAssertTrue(sent.contains("the toolbar area"), "spatial region missing from planner request")
        XCTAssertTrue(sent.contains("Prefers archive folders"), "memory context missing from planner request")
        XCTAssertTrue(sent.contains("com.apple.finder"), "app identity missing from planner request")
        XCTAssertTrue(sent.contains("Tags"), "visible controls missing from planner request")
    }

    func testDoneSignalEndsTheSession() async throws {
        let planner = planner(reply: { #"{"done":true}"# })
        let decision = try await planner.nextStep(goal: "g", observation: observation(), context: .empty)
        XCTAssertEqual(decision, .complete(evidence: .explanationOnly))
    }

    func testInventedElementIDIsRejected() async throws {
        let planner = planner(reply: { #"{"step":{"instruction":"ghost","target":"invented"}}"# })
        do {
            _ = try await planner.nextStep(goal: "g", observation: observation(), context: .empty)
            XCTFail("expected invalidTarget")
        } catch GuidePlannerError.invalidTarget {}
    }

    func testOutOfWindowPointIsRejected() async throws {
        let planner = planner(reply: { #"{"step":{"instruction":"far","target":[5000,5000]}}"# })
        do {
            _ = try await planner.nextStep(goal: "g", observation: observation(), context: .empty)
            XCTFail("expected invalidTarget")
        } catch GuidePlannerError.invalidTarget {}
    }

    func testMalformedResponseSurfacesHonestly() async throws {
        let planner = planner(reply: { "not json at all" })
        do {
            _ = try await planner.nextStep(goal: "g", observation: observation(), context: .empty)
            XCTFail("expected malformedResponse")
        } catch GuidePlannerError.malformedResponse {}
    }

    func testCompletionFailureSurfacesUnchanged() async throws {
        struct Offline: Error {}
        let planner = planner(reply: { throw Offline() })
        do {
            _ = try await planner.nextStep(goal: "g", observation: observation(), context: .empty)
            XCTFail("expected failure")
        } catch is Offline {}
    }

    func testVisiblePathRejectsAnyUngroundedStep() async throws {
        let planner = planner(reply: {
            #"{"steps":[{"instruction":"click Tags","target":"b1"},{"instruction":"ghost","target":"invented"},{"instruction":"click Share","target":"s1"}]}"#
        })

        do {
            _ = try await planner.visiblePath(goal: "tag a file", observation: observation(), context: .empty)
            XCTFail("expected invalidTarget")
        } catch GuidePlannerError.invalidTarget {}
    }

    func testVisiblePathReturnsGroundedSteps() async throws {
        let planner = planner(reply: {
            #"{"steps":[{"instruction":"click Tags","target":"b1"},{"instruction":"click Share","target":"s1"}]}"#
        })

        let steps = try await planner.visiblePath(goal: "tag a file", observation: observation(), context: .empty)

        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps.map(\.instruction), ["click Tags", "click Share"])
        for step in steps {
            guard case .axElement(let id) = step.target else {
                return XCTFail("visible path must only contain grounded targets")
            }
            XCTAssertNotNil(observation().snapshot.element(withStableID: id))
        }
    }

    func testVisiblePathRejectsMoreThanTwentyFiveSteps() async throws {
        let list = (0..<26).map { #"{"instruction":"click \#($0)","target":"b1"}"# }.joined(separator: ",")
        let planner = planner(reply: {
            "{\"steps\":[\(list)]}"
        })

        do {
            _ = try await planner.visiblePath(goal: "tag a file", observation: observation(), context: .empty)
            XCTFail("expected malformedResponse")
        } catch GuidePlannerError.malformedResponse {}
    }

    func testParserRejectsMalformedResponses() {
        let malformed: [String] = [
            #"Here is your step: {"step":{"instruction":"x","target":"b1"}}"#,
            #"{"step":{"instruction":"x","target":"b1"}} hope that helps"#,
            "```json\n{\"step\":{\"instruction\":\"x\",\"target\":\"b1\"}}\n```",
            #"{"done":true} {"step":{"instruction":"x","target":"b1"}}"#,
            #"{"done":false}"#,
            #"{"done":false,"done":true}"#,
            #"{"done":true,}"#,
            #"{"needs_input":{"prompt":"Which?","choices":["a",]}}"#,
            #"{"step":{"instruction":"x","target":"b1","target":"s1"}}"#,
            #"{"step":{"instruction":"x","target":"b1","\u0074arget":"s1"}}"#,
            #"{"done":1}"#,
            #"{"done":true,"step":{"instruction":"x","target":"b1"}}"#,
            #"{"step":{"instruction":"x","target":"b1"},"extra":1}"#,
            #"{"step":{"instruction":"x"}}"#,
            #"{"step":{"instruction":"x","target":true}}"#,
            #"{"step":{"instruction":"x","target":""}}"#,
            #"{"step":{"instruction":"x","target":"null"}}"#,
            #"{"step":{"instruction":"x","target":{}}}"#,
            #"{"step":{"instruction":"x","target":{"x":1}}}"#,
            #"{"step":{"instruction":"x","target":[1]}}"#,
            #"{"step":{"instruction":"x","target":{"x":true,"y":2}}}"#,
            #"{"step":{"instruction":"x","target":[true,2]}}"#,
            #"{"step":{"instruction":"x","target":"b1","wait":1}}"#,
            #"{"step":{"instruction":"x","target":"b1","wait":"yes"}}"#,
            #"{"step":{"instruction":"x","target":"b1","wait":null}}"#,
            #"{"step":{"instruction":"x","target":"b1","bogus":1}}"#,
            #"{"blocked":""}"#,
            #"{"blocked":"   "}"#,
            #"{"blocked":null}"#,
            #"{"needs_input":null}"#,
            #"{"needs_input":{"prompt":"","choices":[]}}"#,
            #"{"needs_input":{"prompt":"  ","choices":["a"]}}"#,
            #"{"needs_input":{"prompt":"x"}}"#,
            #"{"needs_input":{"prompt":"x","choices":null}}"#,
            #"{"needs_input":{"prompt":"x","choices":["a","b","c","d","e"]}}"#,
            #"{"needs_input":{"prompt":"x","choices":["a",""]}}"#,
            #"{"needs_input":{"prompt":"x","choices":[],"extra":1}}"#,
        ]
        for body in malformed {
            XCTAssertThrowsError(
                try RuntimeGuidePlanner.parseNextStep(text: body, observation: observation()),
                body
            ) { error in
                guard case .malformedResponse = error as? GuidePlannerError else {
                    return XCTFail("\(body): expected malformedResponse, got \(error)")
                }
            }
        }
    }

    func testParserAcceptsValidResponses() throws {
        XCTAssertEqual(
            try RuntimeGuidePlanner.parseNextStep(
                text: "  \n {\"done\":true} \n",
                observation: observation()
            ),
            .complete(evidence: .explanationOnly)
        )

        guard case .step(let verbal) = try RuntimeGuidePlanner.parseNextStep(
            text: #"{"step":{"instruction":"look at the toolbar","target":null,"wait":false}}"#,
            observation: observation()
        ) else {
            return XCTFail("expected step decision")
        }
        XCTAssertEqual(verbal.target.isVerbal, true)
        XCTAssertEqual(verbal.waitForUserAction, false)

        guard case .step(let element) = try RuntimeGuidePlanner.parseNextStep(
            text: #"{"step":{"instruction":"click Tags","target":"b1"}}"#,
            observation: observation()
        ) else {
            return XCTFail("expected step decision")
        }
        guard case .axElement(let id) = element.target else {
            return XCTFail("expected element target")
        }
        XCTAssertEqual(id, "b1")
        XCTAssertEqual(element.waitForUserAction, true)

        guard case .step(let pair) = try RuntimeGuidePlanner.parseNextStep(
            text: #"{"step":{"instruction":"click there","target":[10,20]}}"#,
            observation: observation()
        ) else {
            return XCTFail("expected step decision")
        }
        guard case .screenPoint(let p1) = pair.target else {
            return XCTFail("expected point target")
        }
        XCTAssertEqual(p1.x, 10)
        XCTAssertEqual(p1.y, 20)

        guard case .step(let dict) = try RuntimeGuidePlanner.parseNextStep(
            text: #"{"step":{"instruction":"click there","target":{"x":10.5,"y":20.25}}}"#,
            observation: observation()
        ) else {
            return XCTFail("expected step decision")
        }
        guard case .screenPoint(let p2) = dict.target else {
            return XCTFail("expected point target")
        }
        XCTAssertEqual(p2.x, 10.5)
        XCTAssertEqual(p2.y, 20.25)
    }

    func testOpensWindowFlagIsAcceptedAndDecoded() throws {
        guard case .step(let step) = try RuntimeGuidePlanner.parseNextStep(
            text: #"{"step":{"instruction":"open preferences","target":"b1","opens_window":true}}"#,
            observation: observation()
        ) else {
            return XCTFail("expected step decision")
        }
        XCTAssertTrue(step.opensWindow)

        guard case .step(let plain) = try RuntimeGuidePlanner.parseNextStep(
            text: #"{"step":{"instruction":"click Tags","target":"b1"}}"#,
            observation: observation()
        ) else {
            return XCTFail("expected step decision")
        }
        XCTAssertFalse(plain.opensWindow)
    }

    func testOpensWindowRejectsNonBoolean() {
        XCTAssertThrowsError(try RuntimeGuidePlanner.parseNextStep(
            text: #"{"step":{"instruction":"open preferences","target":"b1","opens_window":"yes"}}"#,
            observation: observation()
        )) { error in
            guard case GuidePlannerError.malformedResponse = error else {
                return XCTFail("expected malformedResponse, got \(error)")
            }
        }
    }

    /// The wire finally carries postconditions — without them click-advance
    /// can only stall waiting for an explicit confirmation.
    func testPostconditionIsAcceptedAndDecoded() throws {
        guard case .step(let step) = try RuntimeGuidePlanner.parseNextStep(
            text: #"{"step":{"instruction":"click Open","target":"b1","post":{"exists":"b2"}}}"#,
            observation: observation()
        ) else {
            return XCTFail("expected step decision")
        }
        XCTAssertEqual(step.postcondition, .elementExists(stableID: "b2"))

        guard case .step(let labelled) = try RuntimeGuidePlanner.parseNextStep(
            text: #"{"step":{"instruction":"save","target":"b1","post":{"label":"b1","equals":"Saved"}}}"#,
            observation: observation()
        ) else {
            return XCTFail("expected step decision")
        }
        XCTAssertEqual(labelled.postcondition, .elementLabelEquals(stableID: "b1", label: "Saved"))

        guard case .step(let titled) = try RuntimeGuidePlanner.parseNextStep(
            text: #"{"step":{"instruction":"open prefs","target":"b1","post":{"window_title":"Preferences"}}}"#,
            observation: observation()
        ) else {
            return XCTFail("expected step decision")
        }
        XCTAssertEqual(titled.postcondition, .windowTitleEquals("Preferences"))
    }

    /// absent/label postconditions reference the element being changed — an
    /// id that is not in the live window can never verify, so it is rejected.
    func testPostconditionRejectsUngroundedElementIDs() {
        XCTAssertThrowsError(try RuntimeGuidePlanner.parseNextStep(
            text: #"{"step":{"instruction":"click","target":"b1","post":{"absent":"nope"}}}"#,
            observation: observation()
        )) { error in
            guard case GuidePlannerError.malformedResponse = error else {
                return XCTFail("expected malformedResponse, got \(error)")
            }
        }
        XCTAssertThrowsError(try RuntimeGuidePlanner.parseNextStep(
            text: #"{"step":{"instruction":"click","target":"b1","post":{"label":"nope","equals":"X"}}}"#,
            observation: observation()
        )) { error in
            guard case GuidePlannerError.malformedResponse = error else {
                return XCTFail("expected malformedResponse, got \(error)")
            }
        }
        XCTAssertThrowsError(try RuntimeGuidePlanner.parseNextStep(
            text: #"{"step":{"instruction":"click","target":"b1","post":{"exists":123}}}"#,
            observation: observation()
        )) { error in
            guard case GuidePlannerError.malformedResponse = error else {
                return XCTFail("expected malformedResponse, got \(error)")
            }
        }
    }

    func testBlockedOutcomeReturnsBlockedDecision() throws {
        let decision = try RuntimeGuidePlanner.parseNextStep(
            text: #"{"blocked":"no matching control is visible"}"#,
            observation: observation()
        )
        XCTAssertEqual(decision, .blocked(reason: "no matching control is visible"))
    }

    func testJSONKeysAreScopedToTheirOwnObjectAndStringsStayOpaque() throws {
        let object = try RuntimeGuidePlanner.strictJSONObject(#"{"items":[{"key":"escaped quote: \" and colon: : and braces: {}"},{"key":"backslash: \\"}]}"#)
        XCTAssertEqual((object["items"] as? [[String: String]])?.count, 2)
        XCTAssertThrowsError(try RuntimeGuidePlanner.strictJSONObject(String(repeating: " ", count: 65_537) + #"{"done":true}"#))
    }

    func testNeedsInputSchemaIsAccepted() throws {
        let decision = try RuntimeGuidePlanner.parseNextStep(
            text: #"{"needs_input":{"prompt":"Which file should I rename?","choices":["a.txt","b.txt"]}}"#,
            observation: observation()
        )
        XCTAssertEqual(decision, .needsInput(prompt: "Which file should I rename?", choices: ["a.txt", "b.txt"]))
    }

    func testEngineSurfacesBlockedPlannerOutcome() async throws {
        let planner = planner(reply: {
            #"{"blocked":"nothing on screen advances this"}"#
        })
        let observer = FixedObserver(observation: observation())
        let engine = GuideEngine(planner: planner, observer: observer)

        do {
            _ = try await engine.start(goal: "g")
            XCTFail("expected blocked")
        } catch GuidePlannerError.blocked(let reason) {
            XCTAssertEqual(reason, "nothing on screen advances this")
        }
        let phase = await engine.phase
        XCTAssertNotEqual(phase, .finished)
    }
}

private struct FixedObserver: GuideObserving {
    let observation: GuideObservation

    func observe() async throws -> GuideObservation {
        observation
    }
}
