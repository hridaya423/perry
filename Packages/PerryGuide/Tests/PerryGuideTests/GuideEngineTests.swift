import XCTest
@testable import PerryGuide
import PerryCore

private final class StubReader: AXTreeReading, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [AXSnapshot]
    private var index = 0

    init(snapshots: [AXSnapshot]) {
        self.snapshots = snapshots
    }

    func readFrontmost() async throws -> AXSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let snapshot = snapshots[min(index, snapshots.count - 1)]
        index += 1
        return snapshot
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

    private func makeEngine(
        steps: Int,
        changesOnAct: Bool
    ) async throws -> (GuideEngine, StubReader) {
        func window(_ count: Int) -> AXSnapshot {
            AXSnapshot(
                appBundleID: "com.apple.finder",
                windowTitle: "Desktop",
                elements: (steps - count..<steps).map { button("step-\($0)") }
            )
        }

        // Engine read order: start(), then per userActed: before + after.
        // When changesOnAct, each userActed sees the screen lose one element
        // between its before-read and after-read.
        let sequence: [AXSnapshot]
        if changesOnAct {
            sequence = [
                window(steps),   // start
                window(steps),   // act 1 before
                window(steps - 1), // act 1 after (changed)
                window(steps - 1), // act 2 before
                window(max(steps - 2, 0)), // act 2 after (changed)
            ]
        } else {
            sequence = [window(steps)]
        }
        let reader = StubReader(snapshots: sequence)
        let engine = GuideEngine(planner: AXGuidePlanner(), reader: reader)
        return (engine, reader)
    }

    func testPlanFromAXSnapshotProducesOneStepPerControl() async throws {
        let snapshot = AXSnapshot(
            appBundleID: "com.apple.finder",
            windowTitle: "Desktop",
            elements: [
                button("b1", label: "Tags"),
                button("b2", label: "Share"),
            ]
        )
        let plan = try await AXGuidePlanner().plan(goal: "tag a file", snapshot: snapshot)
        XCTAssertEqual(plan.steps.count, 2)
        XCTAssertEqual(plan.steps[0].instruction.contains("this one Tags"), true)
        XCTAssertEqual(plan.steps[1].instruction.hasPrefix("next one"), true)
    }

    func testEmptyScreenProducesVerbalFallback() async throws {
        let snapshot = AXSnapshot(appBundleID: "x", windowTitle: "Canvas", elements: [])
        let plan = try await AXGuidePlanner().plan(goal: "mix a track", snapshot: snapshot)
        XCTAssertEqual(plan.steps.count, 1)
        XCTAssertEqual(plan.steps[0].target.isVerbal, true)
    }

    func testFullGuidedLoopAdvancesOnlyOnScreenChange() async throws {
        let (engine, _) = try await makeEngine(steps: 2, changesOnAct: true)
        let first = try await engine.start(goal: "demo")
        XCTAssertNotNil(first)

        let advance1 = await engine.userActed()
        guard case .advanced(_, let index) = advance1 else {
            return XCTFail("expected advance, got \(advance1)")
        }
        XCTAssertEqual(index, 1)

        let finish = await engine.userActed()
        XCTAssertEqual(finish, .finished)
    }

    func testNoScreenChangeKeepsWaiting() async throws {
        let (engine, reader) = try await makeEngine(steps: 2, changesOnAct: false)
        _ = try await engine.start(goal: "demo")

        let result = await engine.userActed()
        XCTAssertEqual(result, .stillWaiting(stepIndex: 0))
        _ = reader
    }

    func testSkipWalksToCompletion() async throws {
        let (engine, _) = try await makeEngine(steps: 3, changesOnAct: false)
        _ = try await engine.start(goal: "demo")

        let firstSkip = await engine.skip()
        guard case .advanced(_, let index) = firstSkip else {
            return XCTFail("expected advance, got \(firstSkip)")
        }
        XCTAssertEqual(index, 1)

        let secondSkip = await engine.skip()
        guard case .advanced(_, let secondIndex) = secondSkip else {
            return XCTFail("expected advance, got \(secondSkip)")
        }
        XCTAssertEqual(secondIndex, 2)

        let finalSkip = await engine.skip()
        XCTAssertEqual(finalSkip, .finished)
    }
}
