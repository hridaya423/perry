import SwiftUI
import XCTest
@testable import Perry

final class HomeHoverIntentTests: XCTestCase {
    private var intent = HomeHoverIntent()

    override func setUp() {
        intent = HomeHoverIntent()
    }

    func testDwellThenPeek() {
        XCTAssertEqual(intent.entered(at: 0), .none)
        XCTAssertEqual(intent.pendingDeadline, 0.180)
        XCTAssertEqual(intent.deadlineReached(at: 0.179), .none)
        XCTAssertEqual(intent.deadlineReached(at: 0.180), .showPeek)
    }

    func testLeaveBeforeDwellCloses() {
        _ = intent.entered(at: 0)
        XCTAssertEqual(intent.exited(at: 0.05), .none)
        // Stale deadline fire is ignored.
        XCTAssertEqual(intent.deadlineReached(at: 0.19), .none)
    }

    func testTuckAfterExit() {
        _ = intent.entered(at: 0)
        _ = intent.deadlineReached(at: 0.19)
        XCTAssertEqual(intent.exited(at: 0.5), .none)
        XCTAssertEqual(intent.pendingDeadline, 0.85)
        XCTAssertEqual(intent.deadlineReached(at: 0.849), .none)
        XCTAssertEqual(intent.deadlineReached(at: 0.85), .hidePeek)
    }

    func testReentryDuringTuckCancelsClose() {
        _ = intent.entered(at: 0)
        _ = intent.deadlineReached(at: 0.19)
        _ = intent.exited(at: 0.5)
        XCTAssertEqual(intent.entered(at: 0.6), .none)
        // Old tuck deadline passes with no action — peek stays open.
        XCTAssertEqual(intent.deadlineReached(at: 0.85), .none)
        XCTAssertEqual(intent.state, .peekOpen)
    }

    func testEscapeLatchesUntilPointerLeaves() {
        _ = intent.entered(at: 0)
        _ = intent.deadlineReached(at: 0.19)
        XCTAssertEqual(intent.escape(), .hidePeek)
        // Moving within the zone does not reopen.
        XCTAssertEqual(intent.entered(at: 1.0), .none)
        XCTAssertEqual(intent.deadlineReached(at: 2.0), .none)
        _ = intent.exited(at: 3.0)
        // Now a fresh entry dwells again.
        XCTAssertEqual(intent.entered(at: 3.1), .none)
        XCTAssertEqual(intent.deadlineReached(at: 3.29), .showPeek)
    }

    /// Fuzzed pointer paths: random enter/exit/esc/deadline sequences
    /// must never leave the machine with a pending deadline that cannot
    /// resolve, and peek must always end hidden when the pointer is gone.
    func testFuzzedPointerPathsNeverStickOpen() {
        var rng = SplitMix64(seed: 0xC0FFEE)
        var inside = false
        var peekVisible = false

        for _ in 0..<20_000 {
            var m = intent
            let now = TimeInterval(rng.next() % 10_000) / 1000.0
            switch rng.next() % 4 {
            case 0 where !inside:
                inside = true
                if m.entered(at: now) == .showPeek { peekVisible = true }
            case 1 where inside:
                inside = false
                let action = m.exited(at: now)
                if action == .hidePeek { peekVisible = false }
            case 2:
                if m.escape() == .hidePeek { peekVisible = false }
            case 3:
                let action = m.deadlineReached(at: now)
                if action == .showPeek { peekVisible = true }
                if action == .hidePeek { peekVisible = false }
            default:
                continue
            }
            intent = m
            // Invariant: a visible peek implies an open or pending state.
            if peekVisible {
                XCTAssertNotEqual(intent.state, .closed)
                XCTAssertNotEqual(intent.state, .latched)
            }
            // Pointer outside + all deadlines elapsed => nothing stuck.
            if !inside && intent.pendingDeadline == nil {
                XCTAssertEqual(intent.state, .closed)
                XCTAssertFalse(peekVisible)
            }
        }
    }
}

/// Deterministic RNG for the fuzz test (same SplitMix64 the ink code uses).
@MainActor
final class NotchPeekTests: XCTestCase {
    private func peekingController() async throws -> (AppController, () -> Void) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let controller = AppController(debugStorageDirectory: directory)
        let presentation = NotchPresentation.shared
        for entry in presentation.entries { presentation.remove(entry.id) }
        presentation.showsInteraction = true
        controller.showPanel(activate: false)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(controller.sessionPanel.isVisible)
        return (controller, {
            for entry in presentation.entries { presentation.remove(entry.id) }
            controller.collapseNotch()
            controller.notchPresence.stop()
            try? FileManager.default.removeItem(at: directory)
        })
    }

    func testPeekClosesOnHoverOutWhileATaskRuns() async throws {
        let (controller, cleanup) = try await peekingController()
        defer { cleanup() }
        NotchPresentation.shared.present(id: UUID(), priority: .activity, content: Text("Working"), reveal: false)
        XCTAssertEqual(controller.notchPresence.onEndPreview?(), true)
        XCTAssertFalse(controller.sessionPanel.isVisible)
    }

    func testPeekStaysOpenWhileAnApprovalWaits() async throws {
        let (controller, cleanup) = try await peekingController()
        defer { cleanup() }
        NotchPresentation.shared.present(id: UUID(), priority: .approval, content: Text("Approve?"))
        XCTAssertEqual(controller.notchPresence.onEndPreview?(), false)
        XCTAssertTrue(controller.sessionPanel.isVisible)
    }

    func testPeekBecomesVisibleWithin80msOfTheDwell() async throws {
        let (controller, cleanup) = try await peekingController()
        defer { cleanup() }
        controller.endPeek()
        try await Task.sleep(for: .milliseconds(600))
        var samples: [Double] = []
        for _ in 0..<20 {
            let start = ContinuousClock.now
            controller.showPeek()
            let elapsed = ContinuousClock.now - start
            samples.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
            XCTAssertTrue(controller.sessionPanel.isVisible)
            controller.endPeek()
            try await Task.sleep(for: .milliseconds(600))
        }
        let sorted = samples.sorted()
        let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
        print("notch.peek_show_ms p50=\(sorted[sorted.count / 2]) p95=\(p95) max=\(sorted.last!)")
        XCTAssertLessThan(p95, 80)
    }

    func testPeekRowsPutTheApprovalFirstThenTwoTasks() {
        let approval = PeekRow(id: "a", kind: .needsYou, title: "Perry needs your OK", status: "Open it to continue")
        let tasks = (1...3).map { PeekRow(id: "t\($0)", kind: .task(working: true), title: "Task \($0)", status: "Working…") }
        let perry = PeekRow(id: "p", kind: .perry, title: "Morning brief", status: "Summarize newsletters")
        XCTAssertEqual(PeekRow.rows(needsYou: approval, tasks: tasks, perrys: [perry], suggestions: []).map(\.id), ["a", "t1", "t2"])
        XCTAssertEqual(PeekRow.rows(needsYou: nil, tasks: [], perrys: [perry, perry], suggestions: [perry]).count, 2)
    }

    func testHoverOutDoesNotCancelAVoiceTurn() async throws {
        let (controller, cleanup) = try await peekingController()
        defer {
            controller.conversationVoice.cancel()
            cleanup()
        }
        controller.conversationVoice.start()
        XCTAssertEqual(controller.conversationVoice.state, .requestingPermission)
        XCTAssertEqual(controller.notchPresence.onEndPreview?(), true)
        XCTAssertEqual(controller.conversationVoice.state, .requestingPermission)
    }
}

private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
