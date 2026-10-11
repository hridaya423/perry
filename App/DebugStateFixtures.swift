#if DEBUG
import AppKit
import Foundation
import PerryCore
import PerryGuide

/// Deterministic product-state fixtures for design review, UI tests, and
/// screenshot/AX captures. Opened via the `--perry-debug-state <name>` launch
/// argument or the DEBUG "State fixtures" menu. This file compiles only in
/// DEBUG; no production path depends on it.
enum DebugStateFixture: String, CaseIterable, Identifiable {
    case loading
    case empty
    case permissionDenied = "permission-denied"
    case runtimeMissing = "runtime-missing"
    case planning
    case running
    case paused
    case approvalOrange = "approval-orange"
    case approvalRed = "approval-red"
    case verified
    case unverified
    case failed
    case recovered
    case erased

    var id: String { rawValue }

    var title: String {
        switch self {
        case .loading: return "Loading"
        case .empty: return "Empty"
        case .permissionDenied: return "Permission denied"
        case .runtimeMissing: return "Runtime missing"
        case .planning: return "Planning"
        case .running: return "Running"
        case .paused: return "Paused"
        case .approvalOrange: return "Approval (orange)"
        case .approvalRed: return "Approval (red)"
        case .verified: return "Verified"
        case .unverified: return "Unverified"
        case .failed: return "Failed"
        case .recovered: return "Recovered"
        case .erased: return "Erased"
        }
    }

    /// Status text the session panel shows for this fixture. UI tests assert
    /// on these strings; keep them honest rather than marketing copy.
    var statusText: String? {
        switch self {
        case .loading:
            return "Reading the screen before I answer…"
        case .empty:
            return "Press ⌥⌘P when you want Perry."
        case .runtimeMissing:
            return "Perry can't find a usable runtime. Open Settings → Runtimes to install or repair one."
        case .planning:
            return "Planning the first safe step…"
        case .running:
            return "Working: 2 of 5 steps done."
        case .paused:
            return "Paused — resume when you're ready."
        case .verified:
            return "Verified: both files moved and contents unchanged."
        case .unverified:
            return "Finished, but I couldn't verify the result — check before relying on it."
        case .failed:
            return "Stopped: the target window closed before the second step."
        case .recovered:
            return "Recovered the interrupted task after relaunch; no step replayed."
        case .erased:
            return "All Perry data erased."
        case .permissionDenied, .approvalOrange, .approvalRed:
            return nil
        }
    }

    /// Session state to install for panel fixtures; nil for fixtures that
    /// present their own window (approvals, onboarding).
    var sessionState: SessionState? {
        switch self {
        case .loading:
            return .invoking(InvocationState(startedAt: Date()))
        case .planning:
            return .executing(execution(lifecycle: .starting, steps: 5))
        case .running:
            return .executing(execution(
                lifecycle: .running,
                steps: 5,
                evidence: [
                    step("fixture-step-1", "Opened the sample document", index: 0),
                    step("fixture-step-2", "Located the destination folder", index: 1),
                ]
            ))
        case .paused:
            return .executing(execution(
                lifecycle: .paused,
                steps: 5,
                evidence: [step("fixture-step-1", "Copied the first sample", index: 0)]
            ))
        case .verified:
            return .reporting(ReportState(
                taskID: Self.fixtureTaskID,
                summary: "Verified: both files moved and contents unchanged."
            ))
        case .unverified:
            return .reporting(ReportState(
                taskID: Self.fixtureTaskID,
                summary: "Finished, but the result could not be verified."
            ))
        case .failed:
            return .failed(SessionFailure(
                taskID: Self.fixtureTaskID,
                goal: "Move the two named files",
                message: "The target window closed before the second step."
            ))
        case .recovered:
            return .reporting(ReportState(
                taskID: Self.fixtureTaskID,
                summary: "Recovered the interrupted task after relaunch; no step replayed."
            ))
        case .empty, .erased, .runtimeMissing:
            return .idle
        case .permissionDenied, .approvalOrange, .approvalRed:
            return nil
        }
    }

    /// Intent card for approval fixtures.
    var intentCard: IntentCard? {
        switch self {
        case .approvalOrange:
            return IntentCard(
                id: Self.fixtureApprovalID,
                title: "About to move 2 files into Archive",
                detail: "Both files keep their contents; nothing else changes.",
                tier: .orange,
                targetSummary: "draft-a.txt, draft-b.txt → ~/Documents/Archive",
                approveLabel: "Move 2 files into Archive",
                reversible: true
            )
        case .approvalRed:
            return IntentCard(
                id: Self.fixtureApprovalID,
                title: "About to empty the Trash",
                detail: "This cannot be undone from inside Perry.",
                tier: .red,
                targetSummary: "Trash — 34 items",
                approveLabel: "Empty the Trash",
                reversible: false
            )
        default:
            return nil
        }
    }

    init?(arguments: [String]) {
        guard let index = arguments.firstIndex(of: "--perry-debug-state"),
              arguments.indices.contains(index + 1) else { return nil }
        self.init(rawValue: arguments[index + 1])
    }

    private static let fixtureTaskID = UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!
    private static let fixtureApprovalID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!

    private func execution(
        lifecycle: ExecutionLifecycle,
        steps totalSteps: Int,
        evidence: [ExecutionStepEvidence] = []
    ) -> ExecutionSessionState {
        ExecutionSessionState(
            taskID: Self.fixtureTaskID,
            goal: "Move the two named files into Archive",
            startedAt: Date().addingTimeInterval(-20),
            appBundleID: "com.apple.finder",
            workspace: URL(fileURLWithPath: "/tmp/perry-fixture-workspace"),
            lifecycle: lifecycle,
            stepEvidence: evidence,
            totalSteps: totalSteps
        )
    }

    private func step(
        _ id: String,
        _ summary: String,
        index: Int
    ) -> ExecutionStepEvidence {
        ExecutionStepEvidence(
            id: id,
            summary: summary,
            tier: .green,
            reversible: true,
            startedAt: Date().addingTimeInterval(-10),
            index: index
        )
    }
}

enum PerryDebugLaunchSurface: String, Equatable {
    case settings
    case onboarding
    case session
    case activity
    case guideControls = "guide-controls"
    case history
    case prototypes
    case cursors
    case notch
    case intentCard = "intent-card"
    case backgroundTasksStorageError = "background-tasks-storage-error"

    init?(arguments: [String]) {
        guard let index = arguments.firstIndex(of: "--perry-debug-surface"),
              arguments.indices.contains(index + 1) else { return nil }
        self.init(rawValue: arguments[index + 1])
    }
}

extension PerryDebugLaunchSurface {
    static let intentCardFixture = IntentCard(
        title: "Rename 12 screenshots in ~/PerryDemo",
        detail: "1. Observe Desktop\n2. Select screenshot files\n3. Rename each with its date",
        tier: .orange,
        targetSummary: "12 files",
        approveLabel: "Run",
        reversible: true
    )

    /// Three transcript entries across two days with mixed outcomes, so the
    /// History capture shows a populated surface instead of an empty state.
    static func historyEntries() -> [TranscriptEntry] {
        let day = Calendar.current.startOfDay(for: Date())
        return [
            TranscriptEntry(
                sessionID: UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!,
                request: "Move the two named files into Archive",
                appBundleID: "com.apple.finder",
                summary: "Verified: both files moved and contents unchanged.",
                outcome: .completed,
                startedAt: day.addingTimeInterval(-300),
                finishedAt: day.addingTimeInterval(-280),
                steps: ["Located draft-a.txt", "Moved to ~/Documents/Archive"],
                verified: true
            ),
            TranscriptEntry(
                sessionID: UUID(uuidString: "00000000-0000-0000-0000-0000000000F2")!,
                request: "Guide me through exporting a PDF",
                appBundleID: "com.apple.Preview",
                summary: "Guided: File → Export as PDF completed.",
                outcome: .completed,
                startedAt: day.addingTimeInterval(-86_400),
                finishedAt: day.addingTimeInterval(-86_340),
                steps: ["Opened the File menu", "Pointed at Export as PDF"],
                verified: true
            ),
            TranscriptEntry(
                sessionID: UUID(uuidString: "00000000-0000-0000-0000-0000000000F3")!,
                request: "Rename every screenshot in Downloads",
                appBundleID: "com.apple.finder",
                summary: "Stopped: the target window closed before the second step.",
                outcome: .failed,
                startedAt: day.addingTimeInterval(-86_000),
                finishedAt: day.addingTimeInterval(-85_970),
                steps: ["Renamed Screen Shot 1.png"],
                verified: false
            ),
        ]
    }
}
#endif
