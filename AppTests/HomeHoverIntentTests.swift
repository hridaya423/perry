import XCTest
@testable import Perry

final class HomeHoverIntentTests: XCTestCase {
    private var intent = HomeHoverIntent()

    override func setUp() {
        intent = HomeHoverIntent()
    }

    func testDwellThenPeek() {
        XCTAssertEqual(intent.entered(at: 0), .none)
        XCTAssertEqual(intent.pendingDeadline, 0.110)
        XCTAssertEqual(intent.deadlineReached(at: 0.109), .none)
        XCTAssertEqual(intent.deadlineReached(at: 0.110), .showPeek)
    }

    func testLeaveBeforeDwellCloses() {
        _ = intent.entered(at: 0)
        XCTAssertEqual(intent.exited(at: 0.05), .none)
        // Stale deadline fire is ignored.
        XCTAssertEqual(intent.deadlineReached(at: 0.12), .none)
    }

    func testTuckAfterExit() {
        _ = intent.entered(at: 0)
        _ = intent.deadlineReached(at: 0.12)
        XCTAssertEqual(intent.exited(at: 0.5), .none)
        XCTAssertEqual(intent.pendingDeadline, 0.75)
        XCTAssertEqual(intent.deadlineReached(at: 0.75), .hidePeek)
    }

    func testReentryDuringTuckCancelsClose() {
        _ = intent.entered(at: 0)
        _ = intent.deadlineReached(at: 0.12)
        _ = intent.exited(at: 0.5)
        XCTAssertEqual(intent.entered(at: 0.6), .none)
        // Old tuck deadline passes with no action — peek stays open.
        XCTAssertEqual(intent.deadlineReached(at: 0.75), .none)
        XCTAssertEqual(intent.state, .peekOpen)
    }

    func testEscapeLatchesUntilPointerLeaves() {
        _ = intent.entered(at: 0)
        _ = intent.deadlineReached(at: 0.12)
        XCTAssertEqual(intent.escape(), .hidePeek)
        // Moving within the zone does not reopen.
        XCTAssertEqual(intent.entered(at: 1.0), .none)
        XCTAssertEqual(intent.deadlineReached(at: 2.0), .none)
        _ = intent.exited(at: 3.0)
        // Now a fresh entry dwells again.
        XCTAssertEqual(intent.entered(at: 3.1), .none)
        XCTAssertEqual(intent.deadlineReached(at: 3.22), .showPeek)
    }

    func testHomeOpenSuppressesPeek() {
        intent.homeOpen = true
        XCTAssertEqual(intent.entered(at: 0), .none)
        XCTAssertNil(intent.pendingDeadline)
    }

    func testOpeningHomeHidesPeekImmediately() {
        _ = intent.entered(at: 0)
        _ = intent.deadlineReached(at: 0.12)
        XCTAssertEqual(intent.setHomeOpen(true), .hidePeek)
        XCTAssertEqual(intent.state, .closed)
    }

    /// Fuzzed pointer paths: random enter/exit/esc/deadline/home sequences
    /// must never leave the machine with a pending deadline that cannot
    /// resolve, and peek must always end hidden when the pointer is gone.
    func testFuzzedPointerPathsNeverStickOpen() {
        var rng = SplitMix64(seed: 0xC0FFEE)
        var inside = false
        var homeOpen = false
        var peekVisible = false

        for _ in 0..<20_000 {
            var m = intent
            m.homeOpen = homeOpen
            let now = TimeInterval(rng.next() % 10_000) / 1000.0
            switch rng.next() % 5 {
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
            case 4:
                homeOpen.toggle()
                if m.setHomeOpen(homeOpen) == .hidePeek { peekVisible = false }
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
            if !inside && intent.pendingDeadline == nil && !homeOpen {
                XCTAssertEqual(intent.state, .closed)
                XCTAssertFalse(peekVisible)
            }
        }
    }
}

/// Deterministic RNG for the fuzz test (same SplitMix64 the ink code uses).
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
