import XCTest
@testable import PerryGuide
import PerryCore

private actor StubObserver: GuideObserving {
    private let observations: [GuideObservation]
    private let failureAtRead: Int?
    private var index = 0

    init(observations: [GuideObservation], failureAtRead: Int? = nil) {
        self.observations = observations
        self.failureAtRead = failureAtRead
    }

    init(snapshots: [AXSnapshot], failureAtRead: Int? = nil) {
        self.init(observations: snapshots.map { GuideObservation(snapshot: $0) }, failureAtRead: failureAtRead)
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

    func readCount() -> Int {
        index
    }
}

private enum GuideReaderTestError: Error {
    case captureUnavailable
}

/// Returns steps from a queue, one per planner call, ignoring the observation.
private struct QueueGuidePlanner: GuidePlanner {
    let steps: [GuideStep?]
    private let position = PositionBox()

    final class PositionBox: @unchecked Sendable {
        var index = 0
    }

    func nextStep(goal: String, observation: GuideObservation, progress: GuideProgress, context: GuideContext) async throws -> GuideStep? {
        defer { position.index += 1 }
        guard position.index < steps.count else { return nil }
        return steps[position.index]
    }

    func visiblePath(goal: String, observation: GuideObservation, context: GuideContext) async throws -> [GuideStep] {
        steps.compactMap { $0 }
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

    // MARK: - Dynamic replanning (the Phase 4 gate)

    /// Step two is not drawn from an upfront plan: the planner sees the
    /// changed post-click observation and chooses from what is actually there.
    func testSecondStepIsPlannedFromTheChangedUI() async throws {
        let first = snapshot([button("open", label: "Open")])
        let changed = snapshot([button("insert", label: "Insert Row")])
        let observer = StubObserver(snapshots: [first, changed])

        let planner = ObservationPlanner { observation, _ in
            if observation.snapshot.element(withStableID: "open") != nil {
                return GuideStep(instruction: "open it", target: .axElement(stableID: "open"))
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

    /// The wrong click is ignored: no snapshot read, no advance, same step.
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

        // The click lands inside a real control — just not the highlighted one.
        let result = await engine.acceptClick(at: CGPointShim(x: 245, y: 35))
        XCTAssertEqual(result, .ignoredClick(stepIndex: 0))
    }

    // MARK: - Verification

    func testNoScreenChangeKeepsWaiting() async throws {
        let initial = snapshot([button("target", label: "Open")])
        let observer = StubObserver(snapshots: [initial])
        let planner = QueueGuidePlanner(steps: [
            GuideStep(instruction: "open it", target: .axElement(stableID: "target")),
        ])
        let engine = GuideEngine(planner: planner, observer: observer)
        _ = try await engine.start(goal: "open the file")

        let result = await engine.acceptClick(at: CGPointShim(x: 55, y: 35))
        XCTAssertEqual(result, .stillWaiting(stepIndex: 0))
    }

    func testCaptureFailureBlocksInsteadOfPretendingTheStepWasUnchanged() async throws {
        let initial = snapshot([button("target", label: "Open")])
        let observer = StubObserver(snapshots: [initial], failureAtRead: 1)
        let planner = QueueGuidePlanner(steps: [
            GuideStep(instruction: "open it", target: .axElement(stableID: "target")),
        ])
        let engine = GuideEngine(planner: planner, observer: observer)
        _ = try await engine.start(goal: "open the file")

        let result = await engine.acceptClick(at: CGPointShim(x: 55, y: 35))

        guard case .blocked(let reason) = result else {
            return XCTFail("expected blocked, got \(result)")
        }
        XCTAssertTrue(reason.contains("could not verify"))
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
        XCTAssertEqual(result, .finished)
    }

    // MARK: - Target validation

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
        let planner = QueueGuidePlanner(steps: [
            GuideStep(instruction: "click a", target: .axElement(stableID: "a")),
            GuideStep(instruction: "ghost", target: .axElement(stableID: "invented")),
        ])
        let engine = GuideEngine(planner: planner, observer: observer)
        _ = try await engine.start(goal: "g")

        let result = await engine.acceptClick(at: CGPointShim(x: 55, y: 35))
        guard case .blocked = result else {
            return XCTFail("expected blocked, got \(result)")
        }
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

    // MARK: - Offline planner honesty

    func testFallbackPlannerNamesAMatchingControl() async throws {
        let planner = AXGuidePlanner()
        let observation = GuideObservation(snapshot: snapshot([
            button("b1", label: "Share"),
            button("b2", label: "Tags"),
            button("b3", label: "Preview"),
        ]))

        let step = try await planner.nextStep(goal: "tag a file", observation: observation, context: .empty)
        XCTAssertTrue(step?.instruction.contains("Tags") == true)
    }

    func testFallbackPlannerAdmitsItCannotDeriveAnUnmatchedGoal() async throws {
        let planner = AXGuidePlanner()
        let observation = GuideObservation(snapshot: snapshot([button("b1", label: "Share")]))

        let step = try await planner.nextStep(goal: "compose a symphony", observation: observation, context: .empty)
        XCTAssertEqual(step?.target.isVerbal, true)
        XCTAssertEqual(step?.waitForUserAction, false)
        XCTAssertTrue(step?.instruction.contains("compose a symphony") == true)
    }

    func testFallbackPlannerPointsAtTopControlForGenericWalkthrough() async throws {
        let planner = AXGuidePlanner()
        let observation = GuideObservation(snapshot: snapshot([button("b1", label: "Share")]))

        let step = try await planner.nextStep(goal: "walk me through this window", observation: observation, context: .empty)
        XCTAssertEqual(step?.target.isVerbal, false)
    }

    func testFallbackPlannerNeverRepeatsACompletedTarget() async throws {
        let planner = AXGuidePlanner()
        let observation = GuideObservation(snapshot: snapshot([
            button("b1", label: "Tags"),
            button("b2", label: "Tag Editor"),
        ]))
        var progress = GuideProgress()
        progress.recordCompleted(GuideStep(instruction: "x", target: .axElement(stableID: "b1")))

        let step = try await planner.nextStep(goal: "tag a file", observation: observation, progress: progress, context: .empty)
        if case .axElement(let id)? = step?.target {
            XCTAssertEqual(id, "b2")
        } else {
            XCTFail("expected the second tag control")
        }
    }

    func testFallbackPlannerFinishesWhenNothingMatchesAnymore() async throws {
        let planner = AXGuidePlanner()
        let observation = GuideObservation(snapshot: snapshot([button("b1", label: "Unrelated")]))
        var progress = GuideProgress()
        progress.recordPresented()
        progress.recordCompleted(GuideStep(instruction: "x", target: .axElement(stableID: "b0")))

        let step = try await planner.nextStep(goal: "compose a symphony", observation: observation, progress: progress, context: .empty)
        XCTAssertNil(step)
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

    // MARK: - Loop mechanics

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
                return GuideStep(instruction: "one", target: .axElement(stableID: "a"))
            }
            return GuideStep(instruction: "again", target: .axElement(stableID: "b"))
        }
        let engine = GuideEngine(planner: planner, observer: observer)
        _ = try await engine.start(goal: "g", maximumSteps: 1)

        let result = await engine.acceptClick(at: CGPointShim(x: 55, y: 35))
        XCTAssertEqual(result, .finished)
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
}

private struct ObservationPlanner: GuidePlanner {
    let decide: @Sendable (GuideObservation, GuideProgress) -> GuideStep?

    init(decide: @escaping @Sendable (GuideObservation, GuideProgress) -> GuideStep?) {
        self.decide = decide
    }

    func nextStep(goal: String, observation: GuideObservation, progress: GuideProgress, context: GuideContext) async throws -> GuideStep? {
        decide(observation, progress)
    }

    func visiblePath(goal: String, observation: GuideObservation, context: GuideContext) async throws -> [GuideStep] {
        []
    }
}
