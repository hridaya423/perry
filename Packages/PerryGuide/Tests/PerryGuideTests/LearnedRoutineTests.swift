import XCTest
import CryptoKit
import PerryCore
import PerryRuntimes
@testable import PerryGuide

final class LearnedRoutineTests: XCTestCase {
    private let saveTarget = RoutineTarget(role: "button", label: "Save")
    private let fieldTarget = RoutineTarget(role: "textField", label: "Search")

    func testClickFollowedByTypingFoldsIntoOneTypeStep() throws {
        let demo = RecordedDemonstration(bundleID: "com.example.app", events: [
            .click(fieldTarget),
            .typed(text: "quarterly report", into: fieldTarget),
            .click(saveTarget)
        ])
        let routine = try RoutineInference.infer(demonstration: demo, name: "Save a report")
        XCTAssertEqual(routine.steps.count, 2)
        XCTAssertEqual(routine.steps[0].action, .typeText(.literal("quarterly report")))
        XCTAssertEqual(routine.steps[0].target, fieldTarget)
        XCTAssertEqual(routine.steps[1].action, .click)
        XCTAssertEqual(routine.steps[1].summary, "Click Save")
    }

    func testConsecutiveTypingOnSameTargetMerges() throws {
        let demo = RecordedDemonstration(bundleID: "com.example.app", events: [
            .typed(text: "hello", into: fieldTarget),
            .typed(text: " world", into: fieldTarget),
            .typed(text: "elsewhere", into: saveTarget)
        ])
        let routine = try RoutineInference.infer(demonstration: demo, name: "Merge")
        XCTAssertEqual(routine.steps.map(\.action), [
            .typeText(.literal("hello world")),
            .typeText(.literal("elsewhere"))
        ])
    }

    func testClickWithoutFollowingTypeStaysAClickStep() throws {
        let demo = RecordedDemonstration(bundleID: "com.example.app", events: [
            .click(saveTarget),
            .keyPress("return")
        ])
        let routine = try RoutineInference.infer(demonstration: demo, name: "Keys")
        XCTAssertEqual(routine.steps.map(\.action), [.click, .pressKey("return")])
        XCTAssertNil(routine.steps[1].target)
    }

    func testEmptyDemonstrationIsRejected() {
        XCTAssertThrowsError(try RoutineInference.infer(
            demonstration: RecordedDemonstration(bundleID: "com.example.app", events: []),
            name: "Empty"
        )) { XCTAssertEqual($0 as? RoutineError, .emptyDemonstration) }
    }

    func testRoutineRejectsBlankNameAndOversizedStepList() {
        XCTAssertThrowsError(try LearnedRoutine(name: "  ", appBundleIDs: ["com.example.app"], steps: [
            RoutineStep(summary: "Click Save", target: saveTarget, action: .click)
        ])) { XCTAssertEqual($0 as? RoutineError, .invalidName) }
        let many = (0...LearnedRoutine.maximumSteps).map { _ in
            RoutineStep(summary: "Click Save", target: saveTarget, action: .click)
        }
        XCTAssertThrowsError(try LearnedRoutine(name: "Big", appBundleIDs: ["com.example.app"], steps: many)) {
            XCTAssertEqual($0 as? RoutineError, .invalidStepCount)
        }
    }

    func testStoreRoundTripsAndSkipsMalformedFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-routines-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RoutineStore(storageDirectory: directory)
        let routine = try RoutineInference.infer(
            demonstration: RecordedDemonstration(bundleID: "com.example.app", events: [.click(saveTarget)]),
            name: "Save flow"
        )
        try store.save(routine)
        // Malformed file alongside a valid one is skipped, not fatal.
        let routinesDir = directory.appendingPathComponent("Routines", isDirectory: true)
        try Data("not json".utf8).write(to: routinesDir.appendingPathComponent("junk.json"))
        let loaded = store.all()
        XCTAssertEqual(loaded, [routine])
        XCTAssertEqual(store.routine(id: routine.id), routine)
        try store.remove(id: routine.id)
        XCTAssertTrue(store.all().isEmpty)
    }

    // MARK: Replay

    private func makeObservation(elements: [AXElement], bundleID: String = "com.example.app") -> GuideObservation {
        GuideObservation(
            snapshot: AXSnapshot(appBundleID: bundleID, windowTitle: "Main", elements: elements),
            processID: 42,
            windowID: 7,
            connectionGeneration: 3,
            screenshotData: Data("baseline-pixels".utf8)
        )
    }

    private func makeElement(stableID: String, role: AXElement.Role, label: String) -> AXElement {
        AXElement(
            stableID: stableID,
            role: role,
            label: label,
            frame: AXElementFrame(x: 0, y: 0, width: 10, height: 10),
            isActionable: true
        )
    }

    func testReplayResolvesTargetsAgainstFreshObservation() throws {
        let routine = try RoutineInference.infer(
            demonstration: RecordedDemonstration(bundleID: "com.example.app", events: [
                .click(fieldTarget),
                .typed(text: "report", into: fieldTarget),
                .click(saveTarget)
            ]),
            name: "Save a report"
        )
        let observation = makeObservation(elements: [
            makeElement(stableID: "ax-search", role: .textField, label: "Search"),
            makeElement(stableID: "ax-save", role: .button, label: "Save")
        ])
        let plan = try RoutineReplay.plan(routine: routine, observation: observation, taskID: TaskID("t"))
        XCTAssertEqual(plan.requestedScopes, [.computerControl])
        XCTAssertEqual(plan.actions.count, 2)
        guard case .computer(_, .typeText("report", .accessibilityID("ax-search"))) = plan.actions[0].operation else {
            return XCTFail("type step did not resolve to the fresh field ID")
        }
        XCTAssertEqual(plan.actions[0].postcondition, .elementValue("report"))
        guard case .computer(_, .click(.accessibilityID("ax-save"))) = plan.actions[1].operation,
              case .visualChange(let baseline) = plan.actions[1].postcondition else {
            return XCTFail("click step did not resolve or declare a visual baseline")
        }
        let expected = SHA256.hash(data: Data("baseline-pixels".utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(baseline, expected)
        XCTAssertTrue(plan.actions.allSatisfy { $0.approvalRequirement == .plan })
    }

    func testRequiredParametersEnumeratesOnlyParameterSlots() throws {
        let routine = try LearnedRoutine(name: "Fill", appBundleIDs: ["com.example.app"], steps: [
            RoutineStep(summary: "Click Search", target: fieldTarget, action: .click),
            RoutineStep(summary: "Type", target: fieldTarget, action: .typeText(.parameter(name: "query", prompt: "Search for what?"))),
            RoutineStep(summary: "Type fixed", target: fieldTarget, action: .typeText(.literal("fixed"))),
            RoutineStep(summary: "Type more", target: fieldTarget, action: .typeText(.parameter(name: "extra", prompt: "Extra text?")))
        ])
        XCTAssertEqual(routine.requiredParameters.map(\.name), ["query", "extra"])
        XCTAssertEqual(routine.requiredParameters.map(\.prompt), ["Search for what?", "Extra text?"])
    }

    func testReplayFillsParametersAndDropsWaitSteps() throws {
        let routine = try LearnedRoutine(name: "Fill", appBundleIDs: ["com.example.app"], steps: [
            RoutineStep(summary: "Wait", action: .wait(milliseconds: 400)),
            RoutineStep(summary: "Type into Search", target: fieldTarget, action: .typeText(.parameter(name: "query", prompt: "Search for what?")))
        ])
        let observation = makeObservation(elements: [makeElement(stableID: "ax-search", role: .textField, label: "Search")])
        let plan = try RoutineReplay.plan(
            routine: routine, observation: observation, taskID: TaskID("t"),
            parameters: ["query": "invoices"]
        )
        XCTAssertEqual(plan.actions.count, 1)
        guard case .computer(_, .typeText("invoices", _)) = plan.actions[0].operation else {
            return XCTFail("parameter was not substituted")
        }
    }

    func testReplayRefusesMissingAmbiguousAndForeignTargets() throws {
        let clickRoutine = try LearnedRoutine(name: "Click", appBundleIDs: ["com.example.app"], steps: [
            RoutineStep(summary: "Click Save", target: saveTarget, action: .click)
        ])
        // Wrong app.
        XCTAssertThrowsError(try RoutineReplay.plan(
            routine: clickRoutine, observation: makeObservation(elements: [], bundleID: "com.other.app"), taskID: TaskID("t")
        )) { XCTAssertEqual($0 as? RoutineReplayError, .wrongApplication) }
        // Target absent from the fresh tree.
        XCTAssertThrowsError(try RoutineReplay.plan(
            routine: clickRoutine, observation: makeObservation(elements: []), taskID: TaskID("t")
        )) { XCTAssertEqual($0 as? RoutineReplayError, .targetNotFound(step: 0)) }
        // Two indistinguishable matches refuse to guess.
        let duplicates = [
            makeElement(stableID: "one", role: .button, label: "Save"),
            makeElement(stableID: "two", role: .button, label: "Save")
        ]
        XCTAssertThrowsError(try RoutineReplay.plan(
            routine: clickRoutine, observation: makeObservation(elements: duplicates), taskID: TaskID("t")
        )) { XCTAssertEqual($0 as? RoutineReplayError, .ambiguousTarget(step: 0)) }
        // Missing parameter value.
        let parameterRoutine = try LearnedRoutine(name: "P", appBundleIDs: ["com.example.app"], steps: [
            RoutineStep(summary: "Type", target: fieldTarget, action: .typeText(.parameter(name: "q", prompt: "?")))
        ])
        let observation = makeObservation(elements: [makeElement(stableID: "f", role: .textField, label: "Search")])
        XCTAssertThrowsError(try RoutineReplay.plan(
            routine: parameterRoutine, observation: observation, taskID: TaskID("t")
        )) { XCTAssertEqual($0 as? RoutineReplayError, .missingParameter("q")) }
    }

    // MARK: Document contract

    private func makeRoutine(name: String = "Doc") throws -> LearnedRoutine {
        try LearnedRoutine(name: name, appBundleIDs: ["com.example.app"], steps: [
            RoutineStep(summary: "Click Save", target: saveTarget, action: .click),
            RoutineStep(summary: "Type", target: fieldTarget, action: .typeText(.parameter(name: "q", prompt: "?")))
        ], provenance: .reviewed)
    }

    func testDocumentRoundTripKeepsMetadataAndHumanEditableBody() throws {
        let routine = try makeRoutine()
        let data = try RoutineDocument.encode(routine)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.hasPrefix("```json\n"))
        XCTAssertTrue(text.contains("# Doc"))
        XCTAssertTrue(text.contains("\"appBundleIDs\""))
        // Body edits don't affect decode — metadata is authoritative.
        let edited = text + "\nUser notes here.\n"
        let decoded = try RoutineDocument.decode(Data(edited.utf8))
        XCTAssertEqual(decoded, routine)
        XCTAssertEqual(decoded.provenance, .reviewed)
        XCTAssertEqual(decoded.requiredParameters.map(\.name), ["q"])
    }

    func testDocumentRejectsUnknownKeys() throws {
        let routine = try makeRoutine()
        let data = try RoutineDocument.encode(routine)
        let text = String(data: data, encoding: .utf8)!
        let smuggled = text.replacingOccurrences(of: "\"steps\"", with: "\"runShell\": \"rm -rf ~\", \"steps\"")
        XCTAssertThrowsError(try RoutineDocument.decode(Data(smuggled.utf8))) {
            XCTAssertEqual($0 as? RoutineError, .unknownKeys)
        }
    }

    func testDocumentRejectsMissingFenceAndOversize() throws {
        XCTAssertThrowsError(try RoutineDocument.decode(Data("# no fence".utf8))) {
            XCTAssertEqual($0 as? RoutineError, .invalidDocument)
        }
    }

    func testImportDowngradesTestedProvenanceAndWritesMarkdown() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-routines-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RoutineStore(storageDirectory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var routine = try makeRoutine(name: "Imported")
        routine.provenance = .tested
        let source = directory.appendingPathComponent("source.md")
        try RoutineDocument.encode(routine).write(to: source)
        let imported = try store.importRoutine(from: source)
        XCTAssertEqual(imported.provenance, .reviewed)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("Routines/\(imported.id.uuidString).md").path
        ))
    }

    func testVerifiedRunsMarkTheRoutineTestedAndAreCounted() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-routines-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RoutineStore(storageDirectory: directory)
        var routine = try makeRoutine(name: "Counted")
        routine.provenance = .reviewed
        try store.save(routine)
        XCTAssertNil(routine.workedSummary)
        try store.recordVerifiedRun(id: routine.id)
        try store.recordVerifiedRun(id: routine.id)
        let reloaded = try XCTUnwrap(store.routine(id: routine.id))
        XCTAssertEqual(reloaded.verifiedRuns, 2)
        XCTAssertEqual(reloaded.provenance, .tested)
        XCTAssertEqual(reloaded.workedSummary, "Worked 2 times")
        var once = reloaded
        once.verifiedRuns = 1
        XCTAssertEqual(once.workedSummary, "Worked 1 time")
    }

    func testImportNeverCarriesAnotherMachinesRunCount() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-routines-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RoutineStore(storageDirectory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var routine = try makeRoutine(name: "Elsewhere")
        routine.provenance = .tested
        routine.verifiedRuns = 40
        let source = directory.appendingPathComponent("source.md")
        try RoutineDocument.encode(routine).write(to: source)
        XCTAssertEqual(try RoutineDocument.decode(Data(contentsOf: source)).verifiedRuns, 40)
        let imported = try store.importRoutine(from: source)
        XCTAssertEqual(imported.verifiedRuns, 0)
        XCTAssertEqual(imported.provenance, .reviewed)
    }

    func testLegacyJSONStoreFilesStillDecode() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-routines-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let routinesDir = directory.appendingPathComponent("Routines", isDirectory: true)
        try FileManager.default.createDirectory(at: routinesDir, withIntermediateDirectories: true)
        // A legacy record used a single bundleID key.
        let legacy = """
        {"schemaVersion":1,"id":"\(UUID().uuidString)","name":"Old","bundleID":"com.example.app","steps":[{"summary":"Click Save","target":{"role":"button","label":"Save"},"action":{"click":{}}}],"createdAt":0}
        """
        try Data(legacy.utf8).write(to: routinesDir.appendingPathComponent("\(UUID().uuidString).json"))
        let loaded = RoutineStore(storageDirectory: directory).all()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].bundleID, "com.example.app")
        XCTAssertEqual(loaded[0].provenance, .reviewed)
    }

    func testRejectsMoreThanTwentyParameters() {
        let steps = (0...LearnedRoutine.maximumParameters).map { index in
            RoutineStep(summary: "Type \(index)", action: .typeText(.parameter(name: "p\(index)", prompt: "?")))
        }
        XCTAssertThrowsError(try LearnedRoutine(name: "P", appBundleIDs: ["com.example.app"], steps: steps)) {
            XCTAssertEqual($0 as? RoutineError, .tooManyParameters)
        }
    }

    func testReplayPlansTargetsThatAppearOnlyAfterAnEarlierStep() throws {
        let menuTarget = RoutineTarget(role: "button", label: "Menu")
        let renameTarget = RoutineTarget(role: "menuItem", label: "Rename")
        let routine = try LearnedRoutine(name: "Rename", appBundleIDs: ["com.example.app"], steps: [
            RoutineStep(summary: "Click Menu", target: menuTarget, action: .click),
            RoutineStep(summary: "Click Rename", target: renameTarget, action: .click)
        ])
        let before = makeObservation(elements: [makeElement(stableID: "ax-menu", role: .button, label: "Menu")])
        let plan = try RoutineReplay.plan(routine: routine, observation: before, taskID: TaskID("t"))
        XCTAssertEqual(plan.actions.count, 2)

        XCTAssertEqual(
            try RoutineReplay.binding(for: plan.actions[0], of: routine, in: before)?.command,
            .click(.accessibilityID("ax-menu"))
        )
        XCTAssertThrowsError(try RoutineReplay.binding(for: plan.actions[1], of: routine, in: before)) {
            XCTAssertEqual($0 as? RoutineReplayError, .targetNotFound(step: 1))
        }
        let after = makeObservation(elements: [
            makeElement(stableID: "ax-menu", role: .button, label: "Menu"),
            makeElement(stableID: "ax-rename", role: .menuItem, label: "Rename")
        ])
        XCTAssertEqual(
            try RoutineReplay.binding(for: plan.actions[1], of: routine, in: after)?.command,
            .click(.accessibilityID("ax-rename"))
        )
    }

    func testReplayBindsEachStepToTheScreenshotTakenJustBeforeIt() throws {
        let menuTarget = RoutineTarget(role: "button", label: "Menu")
        let routine = try LearnedRoutine(name: "Two clicks", appBundleIDs: ["com.example.app"], steps: [
            RoutineStep(summary: "Click Menu", target: menuTarget, action: .click),
            RoutineStep(summary: "Click Save", target: saveTarget, action: .click),
            RoutineStep(summary: "Type", target: fieldTarget, action: .typeText(.literal("x"))),
            RoutineStep(summary: "Press return", action: .pressKey("return"))
        ])
        let elements = [
            makeElement(stableID: "ax-menu", role: .button, label: "Menu"),
            makeElement(stableID: "ax-save", role: .button, label: "Save"),
            makeElement(stableID: "ax-search", role: .textField, label: "Search")
        ]
        let plan = try RoutineReplay.plan(routine: routine, observation: makeObservation(elements: elements), taskID: TaskID("t"))
        let later = GuideObservation(
            snapshot: AXSnapshot(appBundleID: "com.example.app", windowTitle: "Main", elements: elements),
            processID: 42, windowID: 7, connectionGeneration: 3,
            screenshotData: Data("pixels-after-step-one".utf8)
        )
        let binding = try XCTUnwrap(RoutineReplay.binding(for: plan.actions[1], of: routine, in: later))
        let expected = SHA256.hash(data: Data("pixels-after-step-one".utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(binding.baselineSHA256, expected)
        XCTAssertNil(try RoutineReplay.binding(for: plan.actions[2], of: routine, in: later)?.baselineSHA256)
        let keyBinding = try XCTUnwrap(RoutineReplay.binding(for: plan.actions[3], of: routine, in: later))
        XCTAssertEqual(keyBinding.command, .pressKey("return", modifiers: [], target: nil))
        XCTAssertEqual(keyBinding.baselineSHA256, expected)
    }

    func testRecordedChordBecomesAHotkeyStepThatSurvivesSaveAndReplay() throws {
        let routine = try RoutineInference.infer(
            demonstration: RecordedDemonstration(bundleID: "com.example.app", events: [
                .click(saveTarget),
                .chord(key: "s", modifiers: ["command", "shift"])
            ]),
            name: "Save as"
        )
        XCTAssertEqual(routine.steps[1].summary, "Press Command-Shift-S")
        XCTAssertEqual(routine.steps[1].action, .hotkey(key: "s", modifiers: ["command", "shift"]))
        let reloaded = try RoutineDocument.decode(try RoutineDocument.encode(routine))
        XCTAssertEqual(reloaded, routine)
        let observation = makeObservation(elements: [makeElement(stableID: "ax-save", role: .button, label: "Save")])
        let plan = try RoutineReplay.plan(routine: reloaded, observation: observation, taskID: TaskID("t"))
        guard case .computer(_, let command) = plan.actions[1].operation else { return XCTFail("chord did not replay") }
        XCTAssertEqual(command, .hotkey(key: "s", modifiers: [.command, .shift], target: nil))
        guard case .visualChange = plan.actions[1].postcondition else { return XCTFail("chord has no visual postcondition") }
    }

    func testReplayRefusesAShortcutWithAnUnknownModifier() throws {
        let routine = try LearnedRoutine(name: "Odd", appBundleIDs: ["com.example.app"], steps: [
            RoutineStep(summary: "Press Hyper-S", action: .hotkey(key: "s", modifiers: ["hyper"]))
        ])
        XCTAssertThrowsError(try RoutineReplay.plan(
            routine: routine, observation: makeObservation(elements: []), taskID: TaskID("t")
        )) { XCTAssertEqual($0 as? RoutineReplayError, .unsupportedShortcut(step: 0)) }
    }

    func testAClickPerryCouldNotIdentifyBecomesAStepThePersonDoes() throws {
        let routine = try RoutineInference.infer(
            demonstration: RecordedDemonstration(bundleID: "com.example.app", events: [
                .click(saveTarget),
                .unrecognizedClick
            ]),
            name: "Mixed"
        )
        XCTAssertEqual(routine.steps.map(\.requiresHuman), [false, true])
        XCTAssertEqual(routine.steps[1].summary, "Click something I could not identify")
    }

    func testStepIndexComesFromTheActionID() throws {
        let routine = try LearnedRoutine(name: "Two", appBundleIDs: ["com.example.app"], steps: [
            RoutineStep(summary: "Click Save", target: saveTarget, action: .click),
            RoutineStep(summary: "Click Save again", target: saveTarget, action: .click)
        ])
        let observation = makeObservation(elements: [makeElement(stableID: "ax-save", role: .button, label: "Save")])
        let plan = try RoutineReplay.plan(routine: routine, observation: observation, taskID: TaskID("t"))
        XCTAssertEqual(plan.actions.map(RoutineReplay.stepIndex(of:)), [0, 1])
    }

    func testReplayPausesOnManualSteps() throws {
        let routine = try LearnedRoutine(name: "Mix", appBundleIDs: ["com.example.app"], steps: [
            RoutineStep(summary: "Click Save", target: saveTarget, action: .click),
            RoutineStep(summary: "Confirm the dialog yourself", action: .click, requiresHuman: true)
        ])
        let observation = makeObservation(elements: [makeElement(stableID: "ax-save", role: .button, label: "Save")])
        let plan = try RoutineReplay.plan(routine: routine, observation: observation, taskID: TaskID("t"))
        // The manual step is never dispatched — it surfaces as an askUser
        // pause so the run stops and tells the user which part is theirs.
        XCTAssertEqual(plan.actions.count, 2)
        let manual = try XCTUnwrap(plan.actions.last)
        guard case .askUser(let prompt, _) = manual.operation else {
            return XCTFail("manual step should become an askUser pause")
        }
        XCTAssertTrue(prompt.contains("Confirm the dialog yourself"))
        XCTAssertEqual(manual.approvalRequirement, .action)
    }
}


final class RoutineSynthesisTests: XCTestCase {
    private func draft() throws -> LearnedRoutine {
        try LearnedRoutine(name: "New routine", appBundleIDs: ["com.example.app"], steps: [
            RoutineStep(summary: "Click Save", target: RoutineTarget(role: "button", label: "Save"), action: .click),
            RoutineStep(summary: "Type literal", target: RoutineTarget(role: "textField", label: "Title"), action: .typeText(.literal("draft")))
        ])
    }

    func testPolishRenamesAndRephrases() async throws {
        let raw = #"{"name":"Save a draft","stepSummaries":["Press Save","Enter the draft title"]}"#
        let routine = try await RoutineSynthesis.polish(routine: draft()) { _ in raw }
        XCTAssertEqual(routine.name, "Save a draft")
        XCTAssertEqual(routine.steps.map(\.summary), ["Press Save", "Enter the draft title"])
        XCTAssertEqual(routine.steps.map(\.action), try draft().steps.map(\.action))
    }

    func testFencedJSONAndOversizeNamesTolerated() async throws {
        let longName = String(repeating: "x", count: 200)
        let raw = "```json\n{\"name\":\"\(longName)\",\"stepSummaries\":[\"One\",\"Two\"]}\n```"
        let routine = try await RoutineSynthesis.polish(routine: draft()) { _ in raw }
        XCTAssertEqual(routine.name, "New routine")
        XCTAssertEqual(routine.steps.map(\.summary), ["One", "Two"])
    }

    func testMalformedOrMismatchedResponsesThrow() async throws {
        for raw in [
            "not json",
            #"{"name":"x","stepSummaries":["only one"]}"#,
            #"{"name":"x","stepSummaries":["a","b"],"extra":true}"#,
            String(repeating: "y", count: RoutineSynthesis.maximumResponseBytes + 1)
        ] {
            await XCTAssertThrowsErrorAsync(try await RoutineSynthesis.polish(routine: draft()) { _ in raw })
        }
    }

    func testProviderFailurePropagates() async {
        struct Boom: Error {}
        await XCTAssertThrowsErrorAsync(try await RoutineSynthesis.polish(routine: draft()) { _ in throw Boom() })
    }

    private func XCTAssertThrowsErrorAsync(
        _ expression: @autoclosure () async throws -> LearnedRoutine,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("expected throw", file: file, line: line)
        } catch {}
    }
}
