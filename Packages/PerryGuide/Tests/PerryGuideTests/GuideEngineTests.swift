import XCTest
@testable import PerryGuide
import PerryCore

private actor StubObserver: GuideObserving {
    private let observations: [GuideObservation]
    private let failureAtRead: Int?
    private let failureAtProbe: Int?
    private let holdSignals: Bool
    private var index = 0
    private var elementReads = 0
    private var probeReads = 0
    private var scriptedSignals: [Bool]
    private var heldValues: [Bool] = []
    private var heldSignalWaiter: CheckedContinuation<Bool, Never>?
    private var waitingForSignal = false
    private var waitingObserver: CheckedContinuation<Void, Never>?

    init(observations: [GuideObservation], failureAtRead: Int? = nil, failureAtProbe: Int? = nil, signals: [Bool] = [], holdSignals: Bool = false) {
        self.observations = observations
        self.failureAtRead = failureAtRead
        self.failureAtProbe = failureAtProbe
        self.scriptedSignals = signals
        self.holdSignals = holdSignals
    }

    init(snapshots: [AXSnapshot], failureAtRead: Int? = nil, failureAtProbe: Int? = nil, signals: [Bool] = [], holdSignals: Bool = false) {
        self.init(
            observations: snapshots.map {
                GuideObservation(snapshot: $0, processID: 42, windowID: 7, connectionGeneration: 1)
            },
            failureAtRead: failureAtRead,
            failureAtProbe: failureAtProbe,
            signals: signals,
            holdSignals: holdSignals
        )
    }

    func observe() async throws -> GuideObservation {
        if index == failureAtRead {
            index += 1
            throw GuideReaderTestError.captureUnavailable
        }
        let observation = observations[min(index, observations.count - 1)]
        index += 1
        return observation
    }

    func observeElements() async throws -> GuideObservation {
        elementReads += 1
        return try await observe()
    }

    func probeTarget() async throws -> GuideObservation {
        if probeReads == failureAtProbe {
            probeReads += 1
            throw GuideReaderTestError.captureUnavailable
        }
        probeReads += 1
        return observations[min(index, observations.count - 1)]
    }

    func awaitUIChange(within: Duration) async -> Bool {
        if !scriptedSignals.isEmpty { return scriptedSignals.removeFirst() }
        if !heldValues.isEmpty { return heldValues.removeFirst() }
        guard holdSignals else { return false }
        waitingForSignal = true
        waitingObserver?.resume()
        waitingObserver = nil
        return await withCheckedContinuation { heldSignalWaiter = $0 }
    }

    func emit(_ signaled: Bool) {
        if let waiter = heldSignalWaiter {
            heldSignalWaiter = nil
            waitingForSignal = false
            waiter.resume(returning: signaled)
        } else {
            heldValues.append(signaled)
        }
    }

    func untilWaiting() async {
        if waitingForSignal { return }
        await withCheckedContinuation { waitingObserver = $0 }
    }

    func readCount() -> Int {
        index
    }

    func elementReadCount() -> Int {
        elementReads
    }

    func probeReadCount() -> Int {
        probeReads
    }
}

private enum GuideReaderTestError: Error {
    case captureUnavailable
}

private final class CountingPlanner: GuidePlanner, @unchecked Sendable {
    var path: [GuideStep]
    var decisions: [GuideDecision]
    private(set) var nextStepCalls = 0
    private(set) var visiblePathCalls = 0

    init(path: [GuideStep], decisions: [GuideDecision] = []) {
        self.path = path
        self.decisions = decisions
    }

    func nextStep(goal: String, observation: GuideObservation, progress: GuideProgress, context: GuideContext) async throws -> GuideDecision {
        nextStepCalls += 1
        return decisions.isEmpty ? .complete(evidence: .explanationOnly) : decisions.removeFirst()
    }

    func visiblePath(goal: String, observation: GuideObservation, context: GuideContext) async throws -> [GuideStep] {
        visiblePathCalls += 1
        return path
    }
}

private struct QueueGuidePlanner: GuidePlanner {
    let steps: [GuideStep?]
    private let position = PositionBox()

    final class PositionBox: @unchecked Sendable {
        var index = 0
    }

    func nextStep(goal: String, observation: GuideObservation, progress: GuideProgress, context: GuideContext) async throws -> GuideDecision {
        defer { position.index += 1 }
        guard position.index < steps.count, let step = steps[position.index] else {
            return .complete(evidence: .explanationOnly)
        }
        return .step(step)
    }

    func visiblePath(goal: String, observation: GuideObservation, context: GuideContext) async throws -> [GuideStep] {
        defer { position.index = steps.count }
        return steps.compactMap { $0 }
    }
}

final class GuideEngineTests: XCTestCase {
    private func button(_ id: String, label: String? = nil) -> AXElement {
        AXElement(
            stableID: id,
            role: .button,
            label: label,
            frame: AXElementFrame(x: 10, y: 20, width: 90, height: 30),
            isActionable: true
        )
    }

    private func snapshot(_ elements: [AXElement], bundleID: String = "com.apple.finder", title: String = "Desktop") -> AXSnapshot {
        AXSnapshot(appBundleID: bundleID, windowTitle: title, elements: elements)
    }

    private func observation(
        _ elements: [AXElement],
        bundleID: String = "com.apple.finder",
        title: String = "Desktop",
        processID: Int32? = 42,
        windowID: Int64? = 7,
        generation: UInt64? = 1
    ) -> GuideObservation {
        GuideObservation(
            snapshot: snapshot(elements, bundleID: bundleID, title: title),
            processID: processID,
            windowID: windowID,
            connectionGeneration: generation
        )
    }

    func testSecondStepIsPlannedFromTheChangedUI() async throws {
        let first = snapshot([button("open", label: "Open")])
        let changed = snapshot([button("insert", label: "Insert Row")])
        let observer = StubObserver(snapshots: [first, changed])

        let planner = ObservationPlanner { observation, _ in
            if observation.snapshot.element(withStableID: "open") != nil {
                return GuideStep(instruction: "open it", target: .axElement(stableID: "open"), postcondition: .elementAbsent(stableID: "open"))
            }
            if observation.snapshot.element(withStableID: "insert") != nil {
                return GuideStep(instruction: "insert a row", target: .axElement(stableID: "insert"))
            }
            return nil
        }
        let engine = GuideEngine(planner: planner, observer: observer)

        let firstStep = try await engine.start(goal: "add a row")
        XCTAssertEqual(firstStep?.instruction, "open it")

        let result = await engine.acceptClick(at: CGPointShim(x: 55, y: 35))
        guard case .advanced(let next, let index) = result else {
            return XCTFail("expected advance, got \(result)")
        }
        XCTAssertEqual(index, 1)
        XCTAssertEqual(next.instruction, "insert a row")
    }

    func testWrongClickDoesNotAdvance() async throws {
        let initial = snapshot([button("target", label: "Open")])
        let observer = StubObserver(snapshots: [initial])
        let planner = QueueGuidePlanner(steps: [
            GuideStep(instruction: "open it", target: .axElement(stableID: "target")),
        ])
        let engine = GuideEngine(planner: planner, observer: observer)
        _ = try await engine.start(goal: "open the file")

        let miss = await engine.acceptClick(at: CGPointShim(x: 400, y: 400))
        XCTAssertEqual(miss, .ignoredClick(stepIndex: 0))
        let reads = await observer.readCount()
        XCTAssertEqual(reads, 1, "a missed click must not consume an observation")
        let phase = await engine.phase
        XCTAssertEqual(phase, .presenting(stepIndex: 0))
    }

    func testAnyClickOnAVerbalStepCountsAsTheUserActing() async throws {
        let initial = snapshot([button("target", label: "Open")])
        let observer = StubObserver(snapshots: [initial])
        let planner = QueueGuidePlanner(steps: [
            GuideStep(instruction: "click the control yourself", target: .verbalOnly),
            GuideStep(instruction: "open it", target: .axElement(stableID: "target")),
        ])
        let engine = GuideEngine(planner: planner, observer: observer)
        _ = try await engine.start(goal: "open the file")

        let result = await engine.acceptClick(at: CGPointShim(x: 400, y: 400))
        guard case .advanced(let next, let index) = result else {
            return XCTFail("expected advance, got \(result)")
        }
        XCTAssertEqual(index, 1)
        XCTAssertEqual(next.instruction, "open it")
    }

    func testClickOnADifferentVisibleControlDoesNotAdvance() async throws {
        let initial = snapshot([
            button("target", label: "Open"),
            AXElement(
                stableID: "other",
                role: .button,
                label: "Other",
                frame: AXElementFrame(x: 200, y: 20, width: 90, height: 30),
                isActionable: true
            ),
        ])
        let observer = StubObserver(snapshots: [initial])
        let planner = QueueGuidePlanner(steps: [
            GuideStep(instruction: "open it", target: .axElement(stableID: "target")),
        ])
        let engine = GuideEngine(planner: planner, observer: observer)
        _ = try await engine.start(goal: "open the file")

        let result = await engine.acceptClick(at: CGPointShim(x: 245, y: 35))
        XCTAssertEqual(result, .ignoredClick(stepIndex: 0, hitLabel: "Other"))
    }

    func testAPlannedStepRingsItsOwnControlAfterTheReadsIndexesShift() async throws {
        func row(_ id: String, _ label: String, y: Double) -> AXElement {
            AXElement(stableID: id, role: .button, label: label,
                      frame: AXElementFrame(x: 10, y: y, width: 180, height: 24), isActionable: true)
        }
        let first = snapshot([row("s1:12", "Appearance", y: 200), row("s1:20", "Dark", y: 300)])
        let second = snapshot([row("s2:12", "Light", y: 300), row("s2:20", "Accent", y: 340), row("s2:25", "Dark", y: 320)])
        let engine = GuideEngine(
            planner: QueueGuidePlanner(steps: [
                GuideStep(instruction: "Click Appearance", target: .axElement(stableID: "s1:12")),
                GuideStep(instruction: "Click Dark", target: .axElement(stableID: "s1:20")),
            ]),
            observer: StubObserver(snapshots: [first, second])
        )
        _ = try await engine.start(goal: "dark mode")

        let result = await engine.acceptClick(at: CGPointShim(x: 100, y: 212))
        guard case .advanced(let next, _) = result else { return XCTFail("expected advance, got \(result)") }
        XCTAssertEqual(next.instruction, "Click Dark")
        let presentation = await engine.currentPresentation()
        XCTAssertEqual(presentation?.target?.stableID, "s2:25")
        XCTAssertEqual(presentation?.target?.label, "Dark")
    }

    func testAMenuItemClickAdvancesWhenItsProofCloseWithTheMenu() async throws {
        let item = AXElement(stableID: "s1:245", role: .menuItem, label: "Show Path Bar",
                             frame: AXElementFrame(x: 10, y: 20, width: 90, height: 30), isActionable: true)
        let engine = GuideEngine(
            planner: QueueGuidePlanner(steps: [
                GuideStep(instruction: "Click Show Path Bar", target: .axElement(stableID: "s1:245"),
                          postcondition: .elementLabelEquals(stableID: "s1:245", label: "Hide Path Bar")),
            ]),
            observer: StubObserver(snapshots: [snapshot([item]), snapshot([button("s2:3", label: "Back")])])
        )
        _ = try await engine.start(goal: "show the path bar")

        let result = await engine.acceptClick(at: CGPointShim(x: 55, y: 35))
        XCTAssertEqual(result, .explanationEnded)
        let progress = await engine.progress
        XCTAssertEqual(progress.userConfirmedInstructions, ["Click Show Path Bar"])
    }

    func testAProofThatWasTrueBeforeTheClickDoesNotVerifyTheStep() async throws {
        let view = AXElement(stableID: "menubar:View", role: .menu, label: "View",
                             frame: AXElementFrame(x: 10, y: 20, width: 90, height: 30), isActionable: true)
        let engine = GuideEngine(
            planner: QueueGuidePlanner(steps: [
                GuideStep(instruction: "Click View", target: .axElement(stableID: "menubar:View"),
                          postcondition: .elementExists(stableID: "menubar:View")),
            ]),
            observer: StubObserver(snapshots: [snapshot([view])])
        )
        _ = try await engine.start(goal: "show the path bar")

        let result = await engine.acceptClick(at: CGPointShim(x: 55, y: 35))
        XCTAssertEqual(result, .explanationEnded)
        let progress = await engine.progress
        XCTAssertEqual(progress.userConfirmedInstructions, ["Click View"])
        XCTAssertTrue(progress.completedInstructions.isEmpty)
    }

    func testAClickThatChangesTheScreenAdvancesWhenItsProofCannotBeSeen() async throws {
        let item = AXElement(stableID: "menu:View/Show Path Bar", role: .menuItem, label: "Show Path Bar",
                             frame: AXElementFrame(x: 10, y: 20, width: 90, height: 30), isActionable: true)
        let engine = GuideEngine(
            planner: QueueGuidePlanner(steps: [
                GuideStep(instruction: "Click Show Path Bar", target: .axElement(stableID: "menu:View/Show Path Bar"),
                          postcondition: .elementExists(stableID: "menu:View/Hide Path Bar")),
            ]),
            observer: StubObserver(snapshots: [snapshot([item]), snapshot([button("s2:3", label: "Back")])])
        )
        _ = try await engine.start(goal: "show the path bar")

        let result = await engine.acceptClick(at: CGPointShim(x: 55, y: 35))
        XCTAssertEqual(result, .explanationEnded)
        let progress = await engine.progress
        XCTAssertEqual(progress.userConfirmedInstructions, ["Click Show Path Bar"])
    }

    func testOpeningAMenuCountsAsTheClickTakingEffect() async throws {
        let view = AXElement(stableID: "menubar:View", role: .menu, label: "View",
                             frame: AXElementFrame(x: 10, y: 20, width: 90, height: 30), isActionable: true)
        let row = button("s1:47", label: "draft-a.txt")
        let item = AXElement(stableID: "menu:View/Show Path Bar", role: .menuItem, label: "Show Path Bar",
                             frame: AXElementFrame(x: 10, y: 60, width: 200, height: 22), isActionable: true)
        let engine = GuideEngine(
            planner: QueueGuidePlanner(steps: [
                GuideStep(instruction: "Click View", target: .axElement(stableID: "menubar:View"),
                          postcondition: .elementAbsent(stableID: "s1:47")),
            ]),
            observer: StubObserver(snapshots: [snapshot([view, row]), snapshot([item, view, row])])
        )
        _ = try await engine.start(goal: "show the path bar")

        let result = await engine.acceptClick(at: CGPointShim(x: 55, y: 35))
        XCTAssertEqual(result, .explanationEnded)
        let progress = await engine.progress
        XCTAssertEqual(progress.userConfirmedInstructions, ["Click View"])
    }

    func testDoneAdvancesAStepWhoseProofNeverAppears() async throws {
        let engine = GuideEngine(
            planner: QueueGuidePlanner(steps: [
                GuideStep(instruction: "open it", target: .axElement(stableID: "target"),
                          postcondition: .elementExists(stableID: "never")),
            ]),
            observer: StubObserver(snapshots: [snapshot([button("target", label: "Open")])])
        )
        _ = try await engine.start(goal: "g")

        let result = await engine.userActed()
        XCTAssertEqual(result, .explanationEnded)
        let progress = await engine.progress
        XCTAssertEqual(progress.userConfirmedInstructions, ["open it"])
        XCTAssertTrue(progress.completedInstructions.isEmpty)
    }

    func testAClickOnAStepWithoutProofCountsAsTheUserDoingIt() async throws {
        let initial = snapshot([button("target", label: "Open")])
        let observer = StubObserver(snapshots: [initial])
        let planner = QueueGuidePlanner(steps: [
            GuideStep(instruction: "open it", target: .axElement(stableID: "target")),
        ])
        let engine = GuideEngine(planner: planner, observer: observer)
        _ = try await engine.start(goal: "open the file")

        let result = await engine.acceptClick(at: CGPointShim(x: 55, y: 35))
        XCTAssertEqual(result, .explanationEnded)
        let progress = await engine.progress
        XCTAssertEqual(progress.userConfirmedInstructions, ["open it"])
        XCTAssertTrue(progress.completedInstructions.isEmpty)
    }

    func testUnrelatedChangeWithoutPostconditionCannotVerifyStep() async throws {
        let initial = snapshot([button("target", label: "Open")])
        let changed = snapshot([button("target", label: "Open"), button("unrelated", label: "Notification")], title: "Other title")
        let engine = GuideEngine(
            planner: QueueGuidePlanner(steps: [GuideStep(instruction: "open it", target: .axElement(stableID: "target"))]),
            observer: StubObserver(snapshots: [initial, changed])
        )
        _ = try await engine.start(goal: "g")
        let result = await engine.acceptClick(at: CGPointShim(x: 55, y: 35))
        XCTAssertEqual(result, .explanationEnded)
        let progress = await engine.progress
        XCTAssertTrue(progress.completedInstructions.isEmpty)
    }

    func testExplicitConfirmationCanAdvanceWithoutObservableChange() async throws {
        let initial = snapshot([button("target", label: "Open")])
        let engine = GuideEngine(
            planner: QueueGuidePlanner(steps: [GuideStep(instruction: "open it", target: .axElement(stableID: "target"))]),
            observer: StubObserver(snapshots: [initial])
        )
        _ = try await engine.start(goal: "g")
        let result = await engine.userActed()
        XCTAssertEqual(result, .explanationEnded)
        let progress = await engine.progress
        XCTAssertTrue(progress.completedInstructions.isEmpty)
        XCTAssertEqual(progress.userConfirmedInstructions, ["open it"])
        XCTAssertEqual(progress.completedTargetIDs, ["target"])
    }

    func testUserConfirmedHistoryIsBoundedAndNeverBecomesVerified() {
        var progress = GuideProgress()
        for index in 0..<20 {
            progress.recordUserConfirmed(GuideStep(instruction: "step \(index)", target: .verbalOnly))
        }
        XCTAssertTrue(progress.completedInstructions.isEmpty)
        XCTAssertEqual(progress.userConfirmedInstructions.count, GuideProgress.historyLimit)
        XCTAssertEqual(progress.userConfirmedInstructions.first, "step 12")
    }

    func testCaptureFailureBlocksInsteadOfPretendingTheStepWasUnchanged() async throws {
        let initial = snapshot([button("target", label: "Open")])
        let observer = StubObserver(snapshots: [initial], failureAtProbe: 0)
        let planner = QueueGuidePlanner(steps: [
            GuideStep(instruction: "open it", target: .axElement(stableID: "target")),
        ])
        let engine = GuideEngine(planner: planner, observer: observer)
        _ = try await engine.start(goal: "open the file")

        let result = await engine.acceptClick(at: CGPointShim(x: 55, y: 35))

        guard case .blocked(let reason) = result else {
            return XCTFail("expected blocked, got \(result)")
        }
        XCTAssertTrue(reason.contains("couldn’t confirm"))
        let phase = await engine.phase
        XCTAssertEqual(phase, .waitingForUser(stepIndex: 0))
    }

    func testPostconditionlessClickProbesIdentityInsteadOfReadingTree() async throws {
        let initial = snapshot([button("target", label: "Open")])
        let observer = StubObserver(snapshots: [initial])
        let engine = GuideEngine(
            planner: QueueGuidePlanner(steps: [
                GuideStep(instruction: "open it", target: .axElement(stableID: "target")),
            ]),
            observer: observer
        )
        _ = try await engine.start(goal: "g")

        let result = await engine.acceptClick(at: CGPointShim(x: 55, y: 35))

        XCTAssertEqual(result, .explanationEnded)
        let probes = await observer.probeReadCount()
        let elementReads = await observer.elementReadCount()
        let reads = await observer.readCount()
        XCTAssertEqual(probes, 1)
        XCTAssertEqual(elementReads, 0)
        XCTAssertEqual(reads, 2)
    }

    func testProbeFailureBlocksPostconditionlessClick() async throws {
        let initial = snapshot([button("target", label: "Open")])
        let observer = StubObserver(snapshots: [initial], failureAtProbe: 0)
        let engine = GuideEngine(
            planner: QueueGuidePlanner(steps: [
                GuideStep(instruction: "open it", target: .axElement(stableID: "target")),
            ]),
            observer: observer
        )
        _ = try await engine.start(goal: "g")

        let result = await engine.acceptClick(at: CGPointShim(x: 55, y: 35))

        guard case .blocked(let reason) = result else {
            return XCTFail("expected blocked, got \(result)")
        }
        XCTAssertTrue(reason.contains("couldn’t confirm"))
        let phase = await engine.phase
        XCTAssertEqual(phase, .waitingForUser(stepIndex: 0))
    }

    func testClickCanAdvanceOnTypedPostconditionWithoutVisualChange() async throws {
        let initial = snapshot([button("target", label: "Open"), button("done", label: "Done")])
        let observer = StubObserver(snapshots: [initial])
        let planner = QueueGuidePlanner(steps: [
            GuideStep(
                instruction: "open it",
                target: .axElement(stableID: "target"),
                postcondition: .elementExists(stableID: "done")
            ),
        ])
        let engine = GuideEngine(planner: planner, observer: observer)
        _ = try await engine.start(goal: "open the file")

        let result = await engine.acceptClick(at: CGPointShim(x: 55, y: 35))
        XCTAssertEqual(result, .explanationEnded)
    }

    func testUnrelatedElementChangeCannotSatisfyDeclaredPostcondition() async throws {
        let initial = snapshot([
            button("target", label: "Open"),
            AXElement(
                stableID: "status",
                role: .staticText,
                label: "Waiting",
                frame: AXElementFrame(x: 10, y: 60, width: 90, height: 20),
                isActionable: false
            ),
        ])
        let changed = snapshot([
            button("target", label: "Open"),
            AXElement(
                stableID: "status",
                role: .staticText,
                label: "Changed",
                frame: AXElementFrame(x: 10, y: 60, width: 90, height: 20),
                isActionable: false
            ),
        ])
        let observer = StubObserver(snapshots: [initial, changed])
        let step = GuideStep(
            instruction: "open it",
            target: .axElement(stableID: "target"),
            postcondition: .elementExists(stableID: "done")
        )
        let planner = QueueGuidePlanner(steps: [step])
        let engine = GuideEngine(planner: planner, observer: observer)
        _ = try await engine.start(goal: "open the file")

        let result = await engine.acceptClick(at: CGPointShim(x: 55, y: 35))
        XCTAssertEqual(result, .stillWaiting(stepIndex: 0))
        let progress = await engine.progress
        XCTAssertTrue(progress.completedInstructions.isEmpty)
        let phase = await engine.phase
        XCTAssertEqual(phase, .waitingForUser(stepIndex: 0))
    }

    func testUnrelatedTitleChangeCannotSatisfyDeclaredPostcondition() async throws {
        let initial = snapshot([button("target", label: "Open")])
        let retitled = snapshot([button("target", label: "Open")], title: "Other")
        let observer = StubObserver(snapshots: [initial, retitled])
        let step = GuideStep(
            instruction: "open it",
            target: .axElement(stableID: "target"),
            postcondition: .elementExists(stableID: "done")
        )
        let planner = QueueGuidePlanner(steps: [step])
        let engine = GuideEngine(planner: planner, observer: observer)
        _ = try await engine.start(goal: "open the file")

        _ = await engine.userActed()
        let progress = await engine.progress
        XCTAssertTrue(progress.completedInstructions.isEmpty)
        XCTAssertEqual(progress.userConfirmedInstructions, ["open it"])
    }

    func testDifferentApplicationCannotSatisfyDeclaredPostcondition() async throws {
        let initial = snapshot([button("target", label: "Open")])
        let otherApp = snapshot(
            [button("target", label: "Open"), button("done", label: "Done")],
            bundleID: "com.apple.TextEdit"
        )
        let observer = StubObserver(snapshots: [initial, otherApp])
        let step = GuideStep(
            instruction: "open it",
            target: .axElement(stableID: "target"),
            postcondition: .elementExists(stableID: "done")
        )
        let planner = QueueGuidePlanner(steps: [step])
        let engine = GuideEngine(planner: planner, observer: observer)
        _ = try await engine.start(goal: "open the file")

        let result = await engine.userActed()
        guard case .blocked = result else {
            return XCTFail("expected blocked, got \(result)")
        }
        let progress = await engine.progress
        XCTAssertTrue(progress.completedInstructions.isEmpty)
        let phase = await engine.phase
        XCTAssertEqual(phase, .waitingForUser(stepIndex: 0))
    }

    func testDeclaredPostconditionAdvancesWhenSatisfied() async throws {
        let initial = snapshot([button("target", label: "Open")])
        let done = snapshot([button("target", label: "Open"), button("done", label: "Done")])
        let observer = StubObserver(snapshots: [initial, done])
        let step = GuideStep(
            instruction: "open it",
            target: .axElement(stableID: "target"),
            postcondition: .elementExists(stableID: "done")
        )
        let planner = QueueGuidePlanner(steps: [step])
        let engine = GuideEngine(planner: planner, observer: observer)
        _ = try await engine.start(goal: "open the file")

        let result = await engine.acceptClick(at: CGPointShim(x: 55, y: 35))
        XCTAssertEqual(result, .explanationEnded)
        let progress = await engine.progress
        XCTAssertEqual(progress.completedInstructions, [step.instruction])
    }

    func testSignalBetweenReadsDrivesReverification() async throws {
        let initial = snapshot([button("target", label: "Open")])
        let mid = snapshot([button("target", label: "Open")])
        let done = snapshot([button("target", label: "Open"), button("done", label: "Done")])
        let observer = StubObserver(snapshots: [initial, mid, done], signals: [false, true])
        let step = GuideStep(
            instruction: "open it",
            target: .axElement(stableID: "target"),
            postcondition: .elementExists(stableID: "done")
        )
        let engine = GuideEngine(planner: QueueGuidePlanner(steps: [step]), observer: observer)
        _ = try await engine.start(goal: "open the file")

        let result = await engine.acceptClick(at: CGPointShim(x: 55, y: 35))
        XCTAssertEqual(result, .explanationEnded)
        let reads = await observer.readCount()
        let elementReads = await observer.elementReadCount()
        XCTAssertEqual(reads, 4)
        XCTAssertEqual(elementReads, 2)
    }

    func testNoSignalVerifiesOnceThenWaits() async throws {
        let initial = snapshot([button("target", label: "Open")])
        let observer = StubObserver(snapshots: [initial, initial])
        let step = GuideStep(
            instruction: "open it",
            target: .axElement(stableID: "target"),
            postcondition: .elementExists(stableID: "done")
        )
        let engine = GuideEngine(planner: QueueGuidePlanner(steps: [step]), observer: observer)
        _ = try await engine.start(goal: "open the file")

        let result = await engine.acceptClick(at: CGPointShim(x: 55, y: 35))
        XCTAssertEqual(result, .stillWaiting(stepIndex: 0))
        let elementReads = await observer.elementReadCount()
        XCTAssertEqual(elementReads, 1)
    }

    func testSignalStormIsBounded() async throws {
        let initial = snapshot([button("target", label: "Open")])
        let observer = StubObserver(
            snapshots: [initial],
            signals: [false, true, true, true, true, true]
        )
        let step = GuideStep(
            instruction: "open it",
            target: .axElement(stableID: "target"),
            postcondition: .elementExists(stableID: "done")
        )
        let engine = GuideEngine(planner: QueueGuidePlanner(steps: [step]), observer: observer)
        _ = try await engine.start(goal: "open the file")

        let result = await engine.acceptClick(at: CGPointShim(x: 55, y: 35))
        XCTAssertEqual(result, .stillWaiting(stepIndex: 0))
        let elementReads = await observer.elementReadCount()
        XCTAssertEqual(elementReads, 4)
    }

    func testStaleVerificationCannotAdvancePastStop() async throws {
        let initial = snapshot([button("target", label: "Open")])
        let done = snapshot([button("target", label: "Open"), button("done", label: "Done")])
        let observer = StubObserver(snapshots: [initial, done], holdSignals: true)
        let step = GuideStep(
            instruction: "open it",
            target: .axElement(stableID: "target"),
            postcondition: .elementExists(stableID: "done")
        )
        let engine = GuideEngine(planner: QueueGuidePlanner(steps: [step]), observer: observer)
        _ = try await engine.start(goal: "open the file")

        async let pending = engine.acceptClick(at: CGPointShim(x: 55, y: 35))
        await observer.untilWaiting()
        await engine.stop()
        await observer.emit(true)

        let result = await pending
        let phase = await engine.phase
        XCTAssertEqual(result, .notPresenting)
        XCTAssertEqual(phase, .idle)
    }

    func testDefaultObserverFallbackStillVerifies() async throws {
        struct FallbackObserver: GuideObserving {
            let first: GuideObservation
            func observe() async throws -> GuideObservation { first }
        }
        let initial = observation([button("target", label: "Open"), button("done", label: "Done")])
        let step = GuideStep(
            instruction: "open it",
            target: .axElement(stableID: "target"),
            postcondition: .elementExists(stableID: "done")
        )
        let engine = GuideEngine(
            planner: QueueGuidePlanner(steps: [step]),
            observer: FallbackObserver(first: initial)
        )
        _ = try await engine.start(goal: "open the file")

        let result = await engine.acceptClick(at: CGPointShim(x: 55, y: 35))
        XCTAssertEqual(result, .explanationEnded)
    }

    private func postconditionEngine(before: GuideObservation, after: GuideObservation, opensWindow: Bool = false) -> GuideEngine {
        let step = GuideStep(
            instruction: "open it",
            target: .axElement(stableID: "target"),
            postcondition: .elementExists(stableID: "done"),
            opensWindow: opensWindow
        )
        return GuideEngine(
            planner: QueueGuidePlanner(steps: [step]),
            observer: StubObserver(observations: [before, after])
        )
    }

    private func assertBlockedWithoutProgress(
        _ result: AdvanceResult,
        engine: GuideEngine,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        guard case .blocked = result else {
            return XCTFail("expected blocked, got \(result)", file: file, line: line)
        }
        let progress = await engine.progress
        XCTAssertTrue(progress.completedInstructions.isEmpty, file: file, line: line)
    }

    func testVerificationBlocksWhenProcessChanges() async throws {
        let engine = postconditionEngine(
            before: observation([button("target", label: "Open")]),
            after: observation(
                [button("target", label: "Open"), button("done", label: "Done")],
                processID: 43
            )
        )
        _ = try await engine.start(goal: "open the file")

        let result = await engine.acceptClick(at: CGPointShim(x: 55, y: 35))
        await assertBlockedWithoutProgress(result, engine: engine)
    }

    func testVerificationBlocksWhenWindowChanges() async throws {
        let engine = postconditionEngine(
            before: observation([button("target", label: "Open")]),
            after: observation(
                [button("target", label: "Open"), button("done", label: "Done")],
                windowID: 8
            )
        )
        _ = try await engine.start(goal: "open the file")

        let result = await engine.userActed()
        await assertBlockedWithoutProgress(result, engine: engine)
    }

    func testPredictedWindowChangeAdvances() async throws {
        let engine = postconditionEngine(
            before: observation([button("target", label: "Open")]),
            after: observation(
                [button("done", label: "Done")],
                title: "Preferences",
                windowID: 8
            ),
            opensWindow: true
        )
        _ = try await engine.start(goal: "open preferences")

        let result = await engine.acceptClick(at: CGPointShim(x: 55, y: 35))
        XCTAssertEqual(result, .explanationEnded)
        let progress = await engine.progress
        XCTAssertEqual(progress.completedInstructions, ["open it"])
    }

    func testOpensWindowDoesNotExcuseProcessChange() async throws {
        let engine = postconditionEngine(
            before: observation([button("target", label: "Open")]),
            after: observation(
                [button("target", label: "Open"), button("done", label: "Done")],
                processID: 43,
                windowID: 8
            ),
            opensWindow: true
        )
        _ = try await engine.start(goal: "open the file")

        let result = await engine.acceptClick(at: CGPointShim(x: 55, y: 35))
        await assertBlockedWithoutProgress(result, engine: engine)
    }

    func testOpensWindowStillRequiresWindowIdentity() async throws {
        let engine = postconditionEngine(
            before: observation([button("target", label: "Open")]),
            after: observation(
                [button("done", label: "Done")],
                windowID: nil
            ),
            opensWindow: true
        )
        _ = try await engine.start(goal: "open the file")

        let result = await engine.acceptClick(at: CGPointShim(x: 55, y: 35))
        await assertBlockedWithoutProgress(result, engine: engine)
    }

    func testPlannedStepsAdvanceWithoutReplanning() async throws {
        let stepA = GuideStep(
            instruction: "open it",
            target: .axElement(stableID: "target"),
            postcondition: .elementExists(stableID: "done")
        )
        let stepB = GuideStep(
            instruction: "confirm",
            target: .axElement(stableID: "done")
        )
        let before = observation([button("target", label: "Open")])
        let after = observation([button("target", label: "Open"), button("done", label: "Done")])
        let observer = StubObserver(observations: [before, after, after])
        let planner = CountingPlanner(path: [stepA, stepB])
        let engine = GuideEngine(planner: planner, observer: observer)

        _ = try await engine.start(goal: "open the file")
        XCTAssertEqual(planner.nextStepCalls, 0)
        XCTAssertEqual(planner.visiblePathCalls, 1)

        let result = await engine.acceptClick(at: CGPointShim(x: 55, y: 35))
        guard case .advanced(let step, _) = result else {
            return XCTFail("expected planned advance, got \(result)")
        }
        XCTAssertEqual(step.instruction, "confirm")
        XCTAssertEqual(planner.nextStepCalls, 0)
    }

    func testDeviationFromThePlanTriggersOneReplan() async throws {
        let stepA = GuideStep(
            instruction: "open it",
            target: .axElement(stableID: "target"),
            postcondition: .elementExists(stableID: "done")
        )
        let stepB = GuideStep(
            instruction: "confirm",
            target: .axElement(stableID: "gone")
        )
        let before = observation([button("target", label: "Open")])
        let after = observation([button("done", label: "Done")])
        let observer = StubObserver(observations: [before, after, after])
        let planner = CountingPlanner(
            path: [stepA, stepB],
            decisions: [.step(GuideStep(instruction: "replanned", target: .axElement(stableID: "done")))]
        )
        let engine = GuideEngine(planner: planner, observer: observer)

        _ = try await engine.start(goal: "open the file")
        let result = await engine.acceptClick(at: CGPointShim(x: 55, y: 35))
        guard case .advanced(let step, _) = result else {
            return XCTFail("expected replanned advance, got \(result)")
        }
        XCTAssertEqual(step.instruction, "replanned")
        XCTAssertEqual(planner.nextStepCalls, 1)
    }

    func testAReplanAfterADeviationSeesAScreenshot() async throws {
        func read(_ elements: [AXElement], shot: Data?) -> GuideObservation {
            GuideObservation(snapshot: snapshot(elements), processID: 42, windowID: 7, connectionGeneration: 1, screenshotData: shot)
        }
        let open = button("target", label: "Open")
        let done = button("done", label: "Done")
        let observer = StubObserver(observations: [read([open], shot: Data([1])), read([done], shot: nil), read([done], shot: Data([2]))])
        let planner = ScreenshotRecordingPlanner(
            path: [
                GuideStep(instruction: "open it", target: .axElement(stableID: "target"), postcondition: .elementExists(stableID: "done")),
                GuideStep(instruction: "confirm", target: .axElement(stableID: "target")),
            ],
            next: GuideStep(instruction: "replanned", target: .axElement(stableID: "done"))
        )
        let engine = GuideEngine(planner: planner, observer: observer)
        _ = try await engine.start(goal: "g")

        let result = await engine.acceptClick(at: CGPointShim(x: 55, y: 35))
        guard case .advanced(let step, _) = result else { return XCTFail("expected advance, got \(result)") }
        XCTAssertEqual(step.instruction, "replanned")
        XCTAssertEqual(planner.screenshots.value, [Data([2])])
    }

    func testSkipDiscardsTheSeededPlan() async throws {
        let stepA = GuideStep(instruction: "open it", target: .axElement(stableID: "target"))
        let stepB = GuideStep(instruction: "confirm", target: .axElement(stableID: "done"))
        let snap = observation([button("target", label: "Open"), button("done", label: "Done")])
        let observer = StubObserver(observations: [snap, snap])
        let planner = CountingPlanner(
            path: [stepA, stepB],
            decisions: [.complete(evidence: .explanationOnly)]
        )
        let engine = GuideEngine(planner: planner, observer: observer)

        _ = try await engine.start(goal: "open the file")
        _ = await engine.skip()
        XCTAssertEqual(planner.nextStepCalls, 1)
    }

    func testSkipStillBlocksAcrossChangedWindowForOpensWindowStep() async throws {
        let otherWindow = observation([button("a", label: "A")], windowID: 8)
        let observer = StubObserver(observations: [
            observation([button("target", label: "Open")]),
            otherWindow,
        ])
        let planner = QueueGuidePlanner(steps: [
            GuideStep(
                instruction: "open it",
                target: .axElement(stableID: "target"),
                opensWindow: true
            ),
        ])
        let engine = GuideEngine(planner: planner, observer: observer)
        _ = try await engine.start(goal: "open the file")

        let result = await engine.skip()
        guard case .blocked = result else {
            return XCTFail("expected blocked, got \(result)")
        }
    }

    func testVerificationToleratesGenerationBumpOnSameWindow() async throws {
        let engine = postconditionEngine(
            before: observation([button("target", label: "Open")]),
            after: observation(
                [button("target", label: "Open"), button("done", label: "Done")],
                generation: 2
            )
        )
        _ = try await engine.start(goal: "open the file")

        let result = await engine.acceptClick(at: CGPointShim(x: 55, y: 35))
        XCTAssertEqual(result, .explanationEnded)
    }

    func testVerificationBlocksWhenRespawnedDriverReportsDifferentWindow() async throws {
        let engine = postconditionEngine(
            before: observation([button("target", label: "Open")]),
            after: observation(
                [button("target", label: "Open"), button("done", label: "Done")],
                windowID: 99,
                generation: 2
            )
        )
        _ = try await engine.start(goal: "open the file")

        let result = await engine.acceptClick(at: CGPointShim(x: 55, y: 35))
        await assertBlockedWithoutProgress(result, engine: engine)
    }

    func testVerificationBlocksWhenIdentityMetadataIsLost() async throws {
        let engine = postconditionEngine(
            before: observation([button("target", label: "Open")]),
            after: observation(
                [button("target", label: "Open"), button("done", label: "Done")],
                processID: nil, windowID: nil, generation: nil
            )
        )
        _ = try await engine.start(goal: "open the file")

        let result = await engine.acceptClick(at: CGPointShim(x: 55, y: 35))
        await assertBlockedWithoutProgress(result, engine: engine)
    }

    func testVerificationBlocksWhenBaselineIdentityIsUnavailable() async throws {
        let engine = postconditionEngine(
            before: observation(
                [button("target", label: "Open")],
                processID: nil, windowID: nil, generation: nil
            ),
            after: observation(
                [button("target", label: "Open"), button("done", label: "Done")],
                processID: nil, windowID: nil, generation: nil
            )
        )
        _ = try await engine.start(goal: "open the file")

        let result = await engine.userActed()
        await assertBlockedWithoutProgress(result, engine: engine)
    }

    func testMatchingIdentityWithSatisfiedPostconditionAdvances() async throws {
        let engine = postconditionEngine(
            before: observation([button("target", label: "Open")]),
            after: observation([button("target", label: "Open"), button("done", label: "Done")])
        )
        _ = try await engine.start(goal: "open the file")

        let result = await engine.acceptClick(at: CGPointShim(x: 55, y: 35))
        XCTAssertEqual(result, .explanationEnded)
        let progress = await engine.progress
        XCTAssertEqual(progress.completedInstructions, ["open it"])
    }

    func testRefreshRejectsChangedWindowIdentity() async throws {
        let initial = observation([button("target", label: "Open")])
        let otherWindow = observation(
            [AXElement(
                stableID: "target",
                role: .button,
                label: "Open",
                frame: AXElementFrame(x: 200, y: 20, width: 90, height: 30),
                isActionable: true
            )],
            windowID: 8
        )
        let observer = StubObserver(observations: [initial, otherWindow])
        let planner = QueueGuidePlanner(steps: [
            GuideStep(instruction: "open it", target: .axElement(stableID: "target")),
        ])
        let engine = GuideEngine(planner: planner, observer: observer)
        _ = try await engine.start(goal: "open the file")

        do {
            _ = try await engine.refreshPresentation()
            XCTFail("expected blocked")
        } catch GuidePlannerError.blocked {}

        let presentation = await engine.currentPresentation()
        XCTAssertEqual(presentation?.target?.stableID, "target")
        XCTAssertEqual(presentation?.target?.frame.x, 10)
    }

    func testSkipBlocksAcrossChangedIdentity() async throws {
        let initial = observation([button("a", label: "A")])
        let otherWindow = observation([button("a", label: "A"), button("b", label: "B")], windowID: 8)
        let observer = StubObserver(observations: [initial, otherWindow])
        let planner = QueueGuidePlanner(steps: [
            GuideStep(instruction: "first", target: .axElement(stableID: "a")),
            GuideStep(instruction: "second", target: .axElement(stableID: "b")),
        ])
        let engine = GuideEngine(planner: planner, observer: observer)
        _ = try await engine.start(goal: "g")

        let result = await engine.skip()
        guard case .blocked = result else {
            return XCTFail("expected blocked, got \(result)")
        }
        let progress = await engine.progress
        XCTAssertEqual(progress.presentedCount, 1, "no new step may be presented after a blocked skip")
    }

    func testRefreshRejectsMissingTargetAndKeepsOriginalPresentation() async throws {
        let initial = observation([button("target", label: "Open")])
        let missingTarget = observation([button("other", label: "Other")])
        let observer = StubObserver(observations: [initial, missingTarget])
        let planner = QueueGuidePlanner(steps: [
            GuideStep(instruction: "open it", target: .axElement(stableID: "target")),
        ])
        let engine = GuideEngine(planner: planner, observer: observer)
        _ = try await engine.start(goal: "open the file")

        do {
            _ = try await engine.refreshPresentation()
            XCTFail("expected invalidTarget")
        } catch GuidePlannerError.invalidTarget {}

        let presentation = await engine.currentPresentation()
        XCTAssertEqual(presentation?.target?.stableID, "target")
        XCTAssertEqual(presentation?.target?.frame.x, 10)
    }

    func testInventedElementIDIsRejectedAtStart() async throws {
        let observer = StubObserver(snapshots: [snapshot([button("real")])])
        let planner = QueueGuidePlanner(steps: [
            GuideStep(instruction: "ghost", target: .axElement(stableID: "invented")),
        ])
        let engine = GuideEngine(planner: planner, observer: observer)

        do {
            _ = try await engine.start(goal: "g")
            XCTFail("expected invalidTarget")
        } catch GuidePlannerError.invalidTarget(let detail) {
            XCTAssertTrue(detail.contains("invented"))
        }
    }

    func testInventedTargetOnReplanBlocksHonestly() async throws {
        let first = snapshot([button("a", label: "A")])
        let changed = snapshot([button("b", label: "B")])
        let observer = StubObserver(snapshots: [first, changed])
        let planner = CountingPlanner(
            path: [
                GuideStep(instruction: "click a", target: .axElement(stableID: "a"), postcondition: .elementAbsent(stableID: "a")),
                GuideStep(instruction: "stale", target: .axElement(stableID: "a")),
            ],
            decisions: [.step(GuideStep(instruction: "ghost", target: .axElement(stableID: "invented")))]
        )
        let engine = GuideEngine(planner: planner, observer: observer)
        _ = try await engine.start(goal: "g")

        let result = await engine.acceptClick(at: CGPointShim(x: 55, y: 35))
        guard case .blocked = result else {
            return XCTFail("expected blocked, got \(result)")
        }
        XCTAssertEqual(planner.nextStepCalls, 1)
    }

    func testOutOfWindowPointIsRejected() async throws {
        let bounds = AXElementFrame(x: 0, y: 0, width: 400, height: 300)
        let observation = GuideObservation(
            snapshot: snapshot([button("a")]),
            windowBounds: bounds
        )
        let observer = StubObserver(observations: [observation])
        let planner = QueueGuidePlanner(steps: [
            GuideStep(instruction: "outside", target: .screenPoint(CGPointShim(x: 500, y: 500))),
        ])
        let engine = GuideEngine(planner: planner, observer: observer)

        do {
            _ = try await engine.start(goal: "g")
            XCTFail("expected invalidTarget")
        } catch GuidePlannerError.invalidTarget {}
    }

    func testStartRejectsUnavailableSelectedStep() async throws {
        let selected = observation([button("a")])
        let steps = [GuideStep(instruction: "one", target: .axElement(stableID: "a"), postcondition: .elementAbsent(stableID: "a"))]
        let engine = GuideEngine(
            planner: QueueGuidePlanner(steps: []),
            observer: StubObserver(observations: [selected])
        )

        do {
            _ = try await engine.start(goal: "g", observation: selected, steps: steps, selectedIndex: 5)
            XCTFail("expected malformedResponse")
        } catch GuidePlannerError.malformedResponse {}
    }

    func testProtectedWindowRefusesToGuide() async throws {
        let protected = snapshot([button("unlock")], bundleID: "com.agilebits.onepassword-osx", title: "Vault")
        let observer = StubObserver(snapshots: [protected])
        let planner = QueueGuidePlanner(steps: [
            GuideStep(instruction: "never", target: .axElement(stableID: "unlock")),
        ])
        let engine = GuideEngine(planner: planner, observer: observer)

        do {
            _ = try await engine.start(goal: "unlock it")
            XCTFail("expected protectedWindow")
        } catch GuidePlannerError.protectedWindow {}
    }

    func testFallbackPlannerNamesAMatchingControl() async throws {
        let planner = AXGuidePlanner()
        let observation = GuideObservation(snapshot: snapshot([
            button("b1", label: "Share"),
            button("b2", label: "Tags"),
            button("b3", label: "Preview"),
        ]))

        let decision = try await planner.nextStep(goal: "tag a file", observation: observation, context: .empty)
        guard case .step(let step) = decision else {
            return XCTFail("expected step, got \(decision)")
        }
        XCTAssertTrue(step.instruction.contains("Tags"))
    }

    func testFallbackPlannerAdmitsItCannotDeriveAnUnmatchedGoal() async throws {
        let planner = AXGuidePlanner()
        let observation = GuideObservation(snapshot: snapshot([button("b1", label: "Share")]))

        let decision = try await planner.nextStep(goal: "compose a symphony", observation: observation, context: .empty)
        guard case .step(let step) = decision else {
            return XCTFail("expected step, got \(decision)")
        }
        XCTAssertEqual(step.target.isVerbal, true)
        XCTAssertEqual(step.waitForUserAction, true)
        XCTAssertTrue(step.instruction.contains("compose a symphony"))
    }

    func testFallbackPlannerPointsAtTopControlForGenericWalkthrough() async throws {
        let planner = AXGuidePlanner()
        let observation = GuideObservation(snapshot: snapshot([button("b1", label: "Share")]))

        let decision = try await planner.nextStep(goal: "walk me through this window", observation: observation, context: .empty)
        guard case .step(let step) = decision else {
            return XCTFail("expected step, got \(decision)")
        }
        XCTAssertEqual(step.target.isVerbal, false)
    }

    func testFallbackPlannerNeverRepeatsACompletedTarget() async throws {
        let planner = AXGuidePlanner()
        let observation = GuideObservation(snapshot: snapshot([
            button("b1", label: "Tags"),
            button("b2", label: "Tag Editor"),
        ]))
        var progress = GuideProgress()
        progress.recordCompleted(GuideStep(instruction: "x", target: .axElement(stableID: "b1")))

        let decision = try await planner.nextStep(goal: "tag a file", observation: observation, progress: progress, context: .empty)
        guard case .step(let step) = decision, case .axElement(let id) = step.target else {
            return XCTFail("expected the second tag control")
        }
        XCTAssertEqual(id, "b2")
    }

    func testFallbackPlannerBlocksWhenNothingMatchesAnymore() async throws {
        let planner = AXGuidePlanner()
        let observation = GuideObservation(snapshot: snapshot([button("b1", label: "Unrelated")]))
        var progress = GuideProgress()
        progress.recordPresented()
        progress.recordCompleted(GuideStep(instruction: "x", target: .axElement(stableID: "b0")))

        let decision = try await planner.nextStep(goal: "compose a symphony", observation: observation, progress: progress, context: .empty)
        guard case .blocked(let reason) = decision else {
            return XCTFail("expected blocked, got \(decision)")
        }
        XCTAssertTrue(reason.contains("couldn’t find the control"))
    }

    func testStartThrowsExplanationEndedForUnverifiedCompletion() async throws {
        let engine = GuideEngine(
            planner: DecisionQueuePlanner(decisions: [.complete(evidence: .explanationOnly)]),
            observer: StubObserver(snapshots: [snapshot([button("a")])])
        )

        do {
            _ = try await engine.start(goal: "g")
            XCTFail("expected explanationEnded")
        } catch GuidePlannerError.explanationEnded {}
        let phase = await engine.phase
        XCTAssertEqual(phase, .idle)
    }

    func testExplanationEndedAfterLastStepIsNotVerifiedFinish() async throws {
        let first = snapshot([button("a", label: "A")])
        let changed = snapshot([button("b", label: "B")])
        let engine = GuideEngine(
            planner: DecisionQueuePlanner(decisions: [.step(GuideStep(instruction: "one", target: .axElement(stableID: "a"), postcondition: .elementAbsent(stableID: "a")))]),
            observer: StubObserver(snapshots: [first, changed])
        )
        _ = try await engine.start(goal: "g")

        let result = await engine.acceptClick(at: CGPointShim(x: 55, y: 35))
        XCTAssertEqual(result, .explanationEnded)
        let progress = await engine.progress
        XCTAssertEqual(progress.completedInstructions, ["one"])
    }

    func testObservedGoalCompletionRequiresMatchingAppOwnedCriterion() async throws {
        let satisfied = observation([button("done", label: "Done")])
        let decision: GuideDecision = .complete(evidence: .observedGoal(.elementExists(stableID: "done")))

        let accepted = GuideEngine(
            planner: DecisionQueuePlanner(decisions: [decision]),
            observer: StubObserver(observations: [satisfied])
        )
        let first = try await accepted.start(
            goal: "g",
            context: GuideContext(goalPostcondition: .elementExists(stableID: "done"))
        )
        XCTAssertNil(first)
        let phase = await accepted.phase
        XCTAssertEqual(phase, .finished)

        let unowned = GuideEngine(
            planner: DecisionQueuePlanner(decisions: [decision]),
            observer: StubObserver(observations: [satisfied])
        )
        do {
            _ = try await unowned.start(goal: "g", context: .empty)
            XCTFail("expected blocked")
        } catch GuidePlannerError.blocked {}

        let unmet = GuideEngine(
            planner: DecisionQueuePlanner(decisions: [decision]),
            observer: StubObserver(observations: [observation([button("a", label: "A")])])
        )
        do {
            _ = try await unmet.start(
                goal: "g",
                context: GuideContext(goalPostcondition: .elementExists(stableID: "done"))
            )
            XCTFail("expected blocked")
        } catch GuidePlannerError.blocked {}
    }

    func testNeedsInputFromStartThrowsTypedError() async throws {
        let engine = GuideEngine(
            planner: DecisionQueuePlanner(decisions: [.needsInput(prompt: "Which file?", choices: ["a.txt", "b.txt"])]),
            observer: StubObserver(snapshots: [snapshot([button("a")])])
        )

        do {
            _ = try await engine.start(goal: "g")
            XCTFail("expected needsInput")
        } catch GuidePlannerError.needsInput(let prompt, let choices) {
            XCTAssertEqual(prompt, "Which file?")
            XCTAssertEqual(choices, ["a.txt", "b.txt"])
        }
    }

    func testNeedsInputDuringAdvanceReturnsTypedResult() async throws {
        let first = snapshot([button("a", label: "A")])
        let changed = snapshot([button("b", label: "B")])
        let engine = GuideEngine(
            planner: DecisionQueuePlanner(decisions: [
                .step(GuideStep(instruction: "one", target: .axElement(stableID: "a"), postcondition: .elementAbsent(stableID: "a"))),
                .needsInput(prompt: "Which file?", choices: ["a.txt", "b.txt"]),
            ]),
            observer: StubObserver(snapshots: [first, changed])
        )
        _ = try await engine.start(goal: "g")

        let result = await engine.acceptClick(at: CGPointShim(x: 55, y: 35))
        XCTAssertEqual(result, .needsInput(prompt: "Which file?", choices: ["a.txt", "b.txt"]))
        let phase = await engine.phase
        XCTAssertEqual(phase, .waitingForUser(stepIndex: 0))
    }

    func testVisiblePathOnlyPaintsGroundedControls() async throws {
        let planner = AXGuidePlanner()
        let observation = GuideObservation(snapshot: snapshot([
            button("b1", label: "Tags"),
            button("b2", label: "Share"),
        ]))

        let steps = try await planner.visiblePath(goal: "tag a file", observation: observation, context: .empty)
        XCTAssertFalse(steps.isEmpty)
        for step in steps {
            guard case .axElement(let id) = step.target else {
                return XCTFail("visible path must only contain grounded targets")
            }
            XCTAssertNotNil(observation.snapshot.element(withStableID: id))
        }
    }

    func testSkipReplansFromAFreshObservation() async throws {
        let first = snapshot([button("a", label: "A")])
        let later = snapshot([button("a", label: "A"), button("b", label: "B")])
        let observer = StubObserver(snapshots: [first, later])
        let planner = ObservationPlanner { observation, progress in
            if progress.presentedCount == 0 {
                return GuideStep(instruction: "first", target: .axElement(stableID: "a"))
            }
            return observation.snapshot.element(withStableID: "b") != nil
                ? GuideStep(instruction: "second", target: .axElement(stableID: "b"))
                : nil
        }
        let engine = GuideEngine(planner: planner, observer: observer)
        _ = try await engine.start(goal: "g")

        let result = await engine.skip()
        guard case .advanced(let step, let index) = result else {
            return XCTFail("expected advance, got \(result)")
        }
        XCTAssertEqual(step.instruction, "second")
        XCTAssertEqual(index, 1)
    }

    func testMaximumStepsBoundsTheWholeSession() async throws {
        let first = snapshot([button("a", label: "A")])
        let changed = snapshot([button("b", label: "B")])
        let observer = StubObserver(snapshots: [first, changed])
        let planner = ObservationPlanner { observation, _ in
            if observation.snapshot.element(withStableID: "a") != nil {
                return GuideStep(instruction: "one", target: .axElement(stableID: "a"), postcondition: .elementAbsent(stableID: "a"))
            }
            return GuideStep(instruction: "again", target: .axElement(stableID: "b"))
        }
        let engine = GuideEngine(planner: planner, observer: observer)
        _ = try await engine.start(goal: "g", maximumSteps: 1)

        let result = await engine.acceptClick(at: CGPointShim(x: 55, y: 35))
        guard case .blocked(let reason) = result else {
            return XCTFail("expected blocked, got \(result)")
        }
        XCTAssertTrue(reason.contains("step limit"))
    }

    func testTimeoutRepointsOnlyOnce() async throws {
        let initial = snapshot([button("target")])
        let repointed = snapshot([
            AXElement(
                stableID: "target",
                role: .button,
                label: "Moved",
                frame: AXElementFrame(x: 200, y: 20, width: 90, height: 30),
                isActionable: true
            ),
        ])
        let observer = StubObserver(snapshots: [initial, repointed, initial])
        let planner = QueueGuidePlanner(steps: [
            GuideStep(instruction: "open it", target: .axElement(stableID: "target")),
        ])
        let engine = GuideEngine(planner: planner, observer: observer)
        _ = try await engine.start(goal: "open the file")

        let first = try await engine.refreshPresentation()
        let second = try await engine.refreshPresentation()
        let readCount = await observer.readCount()

        XCTAssertEqual(first?.target?.frame.x, 200)
        XCTAssertEqual(second?.target?.frame.x, 200)
        XCTAssertEqual(readCount, 2)
    }

    func testRepointCaptureFailureThrowsAndConsumesTheSingleRetry() async throws {
        let initial = snapshot([button("target")])
        let observer = StubObserver(snapshots: [initial], failureAtRead: 1)
        let planner = QueueGuidePlanner(steps: [
            GuideStep(instruction: "open it", target: .axElement(stableID: "target")),
        ])
        let engine = GuideEngine(planner: planner, observer: observer)
        _ = try await engine.start(goal: "open the file")

        do {
            _ = try await engine.refreshPresentation()
            XCTFail("expected refresh failure")
        } catch GuideReaderTestError.captureUnavailable {
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let fallback = try await engine.refreshPresentation()
        let readCount = await observer.readCount()
        XCTAssertEqual(fallback?.target?.stableID, "target")
        XCTAssertEqual(readCount, 2)
    }

    func testCurrentPresentationCarriesTheLiveTarget() async throws {
        let observer = StubObserver(snapshots: [snapshot([button("target", label: "Open")])])
        let planner = QueueGuidePlanner(steps: [
            GuideStep(instruction: "open it", target: .axElement(stableID: "target")),
        ])
        let engine = GuideEngine(planner: planner, observer: observer)
        _ = try await engine.start(goal: "open the file")

        let presentation = await engine.currentPresentation()
        XCTAssertEqual(presentation?.target?.stableID, "target")
        XCTAssertEqual(presentation?.step.instruction, "open it")
    }

    func testProgressHistoryIsBounded() async throws {
        var progress = GuideProgress()
        for index in 0..<20 {
            progress.recordCompleted(GuideStep(
                instruction: "step \(index)",
                target: .axElement(stableID: "t\(index)")
            ))
        }
        XCTAssertEqual(progress.completedInstructions.count, GuideProgress.historyLimit)
        XCTAssertEqual(progress.completedTargetIDs.count, GuideProgress.historyLimit)
        XCTAssertEqual(progress.completedInstructions.first, "step 12")
    }

    func testNeedsInputDuringStartPausesAndResumeFeedsAnswer() async throws {
        let planner = DecisionQueuePlanner(decisions: [
            .needsInput(prompt: "Which account?", choices: ["Work", "Personal"]),
            .step(GuideStep(instruction: "click Save", target: .axElement(stableID: "target"))),
        ])
        let engine = GuideEngine(
            planner: planner,
            observer: StubObserver(snapshots: [snapshot([button("target", label: "Save")])])
        )

        do {
            _ = try await engine.start(goal: "save the file")
            XCTFail("expected needsInput")
        } catch GuidePlannerError.needsInput(let prompt, let choices) {
            XCTAssertEqual(prompt, "Which account?")
            XCTAssertEqual(choices, ["Work", "Personal"])
        }

        let result = await engine.resume(withAnswer: "Work")
        guard case .advanced(let step, _) = result else {
            return XCTFail("expected advance, got \(result)")
        }
        XCTAssertEqual(step.instruction, "click Save")
        XCTAssertNil(planner.recorded.contexts[0].inputAnswer)
        XCTAssertEqual(planner.recorded.contexts[1].inputAnswer, "Work")
    }

    func testConsumedAnswerDoesNotLeakIntoUnrelatedQuestion() async throws {
        let planner = DecisionQueuePlanner(decisions: [
            .step(GuideStep(instruction: "open it", target: .axElement(stableID: "target"))),
            .needsInput(prompt: "Keep going?", choices: ["Yes", "No"]),
            .step(GuideStep(instruction: "click Done", target: .axElement(stableID: "done"))),
            .needsInput(prompt: "Really?", choices: ["Yes", "No"]),
        ])
        let initial = snapshot([button("target", label: "Open"), button("done", label: "Done")])
        let engine = GuideEngine(planner: planner, observer: StubObserver(snapshots: [initial]))
        _ = try await engine.start(goal: "open the file")

        let question = await engine.skip()
        guard case .needsInput(let prompt, let choices) = question else {
            return XCTFail("expected needsInput, got \(question)")
        }
        XCTAssertEqual(prompt, "Keep going?")
        XCTAssertEqual(choices, ["Yes", "No"])

        let advanced = await engine.resume(withAnswer: "Yes")
        guard case .advanced = advanced else {
            return XCTFail("expected advance, got \(advanced)")
        }
        XCTAssertEqual(planner.recorded.contexts[2].inputAnswer, "Yes")

        let unrelated = await engine.skip()
        guard case .needsInput(let secondPrompt, _) = unrelated else {
            return XCTFail("expected the unrelated question, got \(unrelated)")
        }
        XCTAssertEqual(secondPrompt, "Really?")
        XCTAssertNil(planner.recorded.contexts[3].inputAnswer, "consumed answer must not leak into a new question")
    }

    func testResumeWithoutSessionDoesNothing() async {
        let observer = StubObserver(snapshots: [snapshot([button("target")])])
        let engine = GuideEngine(planner: DecisionQueuePlanner(decisions: []), observer: observer)
        let result = await engine.resume(withAnswer: "Yes")
        XCTAssertEqual(result, .notPresenting)
        let reads = await observer.readCount()
        XCTAssertEqual(reads, 0)
    }

    func testResumeWhilePresentingDoesNothing() async throws {
        let planner = DecisionQueuePlanner(decisions: [
            .step(GuideStep(instruction: "open it", target: .axElement(stableID: "target"))),
        ])
        let observer = StubObserver(snapshots: [snapshot([button("target", label: "Open")])])
        let engine = GuideEngine(planner: planner, observer: observer)
        _ = try await engine.start(goal: "open the file")

        let result = await engine.resume(withAnswer: "Yes")
        XCTAssertEqual(result, .notPresenting)
        let reads = await observer.readCount()
        XCTAssertEqual(reads, 1)
    }

    func testBackRePresentsPreviousStep() async throws {
        let before = snapshot([button("a", label: "First")])
        let after = snapshot([button("a", label: "First"), button("b", label: "Second")])
        let observer = StubObserver(snapshots: [before, after])
        let stepA = GuideStep(
            instruction: "do first",
            target: .axElement(stableID: "a"),
            postcondition: .elementExists(stableID: "b")
        )
        let stepB = GuideStep(instruction: "do second", target: .axElement(stableID: "b"))
        let engine = GuideEngine(planner: CountingPlanner(path: [stepA, stepB]), observer: observer)

        _ = try await engine.start(goal: "two steps")
        var canGoBack = await engine.canGoBack
        XCTAssertFalse(canGoBack)
        let firstStepBack = await engine.back()
        XCTAssertEqual(firstStepBack, .notPresenting)

        _ = await engine.acceptClick(at: CGPointShim(x: 55, y: 35))
        canGoBack = await engine.canGoBack
        XCTAssertTrue(canGoBack)
        var presented = await engine.progress.presentedCount
        XCTAssertEqual(presented, 2)

        let result = await engine.back()
        guard case .wentBack(let step, let index) = result else {
            return XCTFail("expected wentBack, got \(result)")
        }
        XCTAssertEqual(step.instruction, "do first")
        XCTAssertEqual(index, 0)
        let phase = await engine.phase
        XCTAssertEqual(phase, .presenting(stepIndex: 0))
        presented = await engine.progress.presentedCount
        XCTAssertEqual(presented, 1)
        canGoBack = await engine.canGoBack
        XCTAssertFalse(canGoBack)
    }

    func testBackToVanishedTargetBlocksWithoutLosingCurrentStep() async throws {
        let before = snapshot([button("a", label: "First")])
        let after = snapshot([button("a", label: "First"), button("b", label: "Second")])
        let gone = snapshot([button("b", label: "Second")])
        let observer = StubObserver(snapshots: [before, after, gone])
        let stepA = GuideStep(
            instruction: "do first",
            target: .axElement(stableID: "a"),
            postcondition: .elementExists(stableID: "b")
        )
        let stepB = GuideStep(instruction: "do second", target: .axElement(stableID: "b"))
        let engine = GuideEngine(planner: CountingPlanner(path: [stepA, stepB]), observer: observer)

        _ = try await engine.start(goal: "two steps")
        _ = await engine.acceptClick(at: CGPointShim(x: 55, y: 35))

        let result = await engine.back()
        guard case .blocked = result else {
            return XCTFail("expected blocked, got \(result)")
        }
        let phase = await engine.phase
        XCTAssertEqual(phase, .waitingForUser(stepIndex: 1))
        let presented = await engine.progress.presentedCount
        XCTAssertEqual(presented, 2)
        let canGoBack = await engine.canGoBack
        XCTAssertTrue(canGoBack)
    }

}

private final class ScreenshotRecordingPlanner: GuidePlanner, @unchecked Sendable {
    let path: [GuideStep]
    let next: GuideStep
    let screenshots = Recorded()

    final class Recorded: @unchecked Sendable {
        var value: [Data?] = []
    }

    init(path: [GuideStep], next: GuideStep) {
        self.path = path
        self.next = next
    }

    func nextStep(goal: String, observation: GuideObservation, progress: GuideProgress, context: GuideContext) async throws -> GuideDecision {
        screenshots.value.append(observation.screenshotData)
        return .step(next)
    }

    func visiblePath(goal: String, observation: GuideObservation, context: GuideContext) async throws -> [GuideStep] {
        path
    }
}

private struct ObservationPlanner: GuidePlanner {
    let decide: @Sendable (GuideObservation, GuideProgress) -> GuideStep?

    init(decide: @escaping @Sendable (GuideObservation, GuideProgress) -> GuideStep?) {
        self.decide = decide
    }

    func nextStep(goal: String, observation: GuideObservation, progress: GuideProgress, context: GuideContext) async throws -> GuideDecision {
        if let step = decide(observation, progress) { return .step(step) }
        return .complete(evidence: .explanationOnly)
    }

    func visiblePath(goal: String, observation: GuideObservation, context: GuideContext) async throws -> [GuideStep] {
        []
    }
}

private struct DecisionQueuePlanner: GuidePlanner {
    let decisions: [GuideDecision]
    private let position = PositionBox()
    let recorded = ContextBox()

    final class PositionBox: @unchecked Sendable {
        var index = 0
    }

    final class ContextBox: @unchecked Sendable {
        var contexts: [GuideContext] = []
    }

    func nextStep(goal: String, observation: GuideObservation, progress: GuideProgress, context: GuideContext) async throws -> GuideDecision {
        defer { position.index += 1 }
        recorded.contexts.append(context)
        guard position.index < decisions.count else { return .complete(evidence: .explanationOnly) }
        return decisions[position.index]
    }

    func visiblePath(goal: String, observation: GuideObservation, context: GuideContext) async throws -> [GuideStep] {
        []
    }


   
}
