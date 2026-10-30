import XCTest
import PerryCore
import PerryGuide
import PerryRuntimes
@testable import Perry

final class ExecutionFinalizerTests: XCTestCase {
    private let finishedAt = Date(timeIntervalSince1970: 1_800_000_100)

    func testFinalizationPersistsCompletionAndEmitsSideEffects() async throws {
        let directory = try makeTemporaryDirectory()
        let transcriptStore = TranscriptStore(directory: directory)
        let memoryStore = MemoryStore(
            storageDirectory: directory,
            configuration: MemoryConfiguration(enabled: true)
        )
        let notifier = RecordingExecutionNotifier()
        let finalizer = ExecutionFinalizer(
            transcriptStore: transcriptStore,
            memoryStore: memoryStore,
            notifier: notifier
        )

        let result = await finalizer.finalize(
            execution: execution(),
            outcome: .completed(stepsRun: 2),
            finishedAt: finishedAt
        )

        XCTAssertTrue(result.issues.isEmpty)
        let transcripts = await transcriptStore.snapshot()
        let memories = await memoryStore.snapshot()
        let notifications = await notifier.snapshot()
        XCTAssertEqual(transcripts, [result.completion.transcript])
        XCTAssertEqual(memories, [result.completion.memory])
        XCTAssertEqual(notifications, [result.completion.notification])
    }

    func testTranscriptFailureStopsDownstreamSuccessSideEffects() async throws {
        let directory = try makeTemporaryDirectory()
        let transcriptsDirectory = directory.appendingPathComponent("Transcripts", isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptsDirectory, withIntermediateDirectories: true)
        try Data("{ corrupt".utf8).write(to: transcriptsDirectory.appendingPathComponent("index.json"))
        let transcriptStore = TranscriptStore(directory: directory, fileManager: RejectingExecutionMoveFileManager())
        let memoryStore = MemoryStore(storageDirectory: directory)
        let notifier = RecordingExecutionNotifier()
        let finalizer = ExecutionFinalizer(
            transcriptStore: transcriptStore,
            memoryStore: memoryStore,
            notifier: notifier
        )

        let result = await finalizer.finalize(
            execution: execution(),
            outcome: .completed(stepsRun: 2),
            finishedAt: finishedAt
        )

        XCTAssertEqual(result.issues, [.transcriptPersistence])
        XCTAssertFalse(result.historySaved)
        let memories = await memoryStore.snapshot()
        let notifications = await notifier.snapshot()
        XCTAssertTrue(memories.isEmpty)
        XCTAssertTrue(notifications.isEmpty)
    }

    func testCompletionPreservesActionIdentityOrderAndVerification() {
        let execution = execution()
        let completion = ExecutionFinalizer.completion(
            execution: execution,
            outcome: .completed(stepsRun: 2),
            finishedAt: finishedAt
        )

        XCTAssertEqual(completion.transcript.steps, ["Rename the file", "Rename the file"])
        XCTAssertEqual(completion.summary, "Done. I ran 2 steps.")
        XCTAssertEqual(completion.transcript.verified, true)
        XCTAssertEqual(completion.notification.kind, .completed)
    }

    func testAHeadlineReplacesTheSuccessAndFailureOpening() {
        let success = ExecutionFinalizer.completion(
            execution: execution(),
            outcome: .completed(stepsRun: 2),
            finishedAt: finishedAt,
            headline: "Done. I’ll remember this routine."
        )
        XCTAssertEqual(success.summary, "Done. I’ll remember this routine.")

        let failure = ExecutionFinalizer.completion(
            execution: execution(),
            outcome: .failed(stepSummary: "Click Export", reason: "gone"),
            finishedAt: finishedAt,
            headline: "I stopped at step 3. I couldn’t find “Export”."
        )
        XCTAssertTrue(failure.summary.hasPrefix("I stopped at step 3. I couldn’t find “Export”. "))
        XCTAssertFalse(failure.summary.contains("Stopped at Click Export"))
    }

    func testTranscriptCarriesTheSelectedProviderRoute() {
        var state = execution()
        state = ExecutionSessionState(
            taskID: state.taskID,
            goal: state.goal,
            startedAt: state.startedAt,
            appBundleID: state.appBundleID,
            providerRoute: "Perry local planner",
            workspace: state.workspace,
            lifecycle: state.lifecycle,
            stepEvidence: state.stepEvidence,
            verificationEvidence: state.verificationEvidence,
            totalSteps: state.totalSteps
        )
        let completion = ExecutionFinalizer.completion(
            execution: state,
            outcome: .completed(stepsRun: 2),
            finishedAt: finishedAt
        )
        XCTAssertEqual(completion.transcript.providerRoute, "Perry local planner")
    }

    func testPartialVerificationDoesNotVerifyTheWholeTask() {
        let completion = ExecutionFinalizer.completion(
            execution: execution(verificationEvidence: [
                ExecutionVerificationEvidence(stepID: "first", verified: true, warning: nil),
            ]),
            outcome: .completed(stepsRun: 2),
            finishedAt: finishedAt
        )

        XCTAssertNil(completion.transcript.verified)
    }

    func testFailedVerificationRemainsFalseWhenOtherEvidenceIsMissing() {
        let completion = ExecutionFinalizer.completion(
            execution: execution(verificationEvidence: [
                ExecutionVerificationEvidence(stepID: "first", verified: false, warning: nil),
            ]),
            outcome: .failed(stepSummary: "Rename the file", reason: "read-back failed"),
            finishedAt: finishedAt
        )

        XCTAssertEqual(completion.transcript.verified, false)
    }

    func testBlockedSummarySaysNothingChangedAndGivesSafeNextStep() {
        let completion = ExecutionFinalizer.completion(
            execution: execution(stepEvidence: [], verificationEvidence: []),
            outcome: .blocked(reason: "the plan was rejected"),
            finishedAt: finishedAt
        )

        XCTAssertTrue(completion.summary.contains("I didn’t change anything"))
        XCTAssertTrue(completion.summary.contains("try again"))
    }

    func testFailedSummaryReportsPartialProgressUncertaintyAndNextStep() {
        let completion = ExecutionFinalizer.completion(
            execution: execution(verificationEvidence: [
                ExecutionVerificationEvidence(stepID: "first", verified: true, warning: nil),
            ]),
            outcome: .failed(stepSummary: "Rename the file", reason: "read-back failed"),
            finishedAt: finishedAt
        )

        XCTAssertTrue(completion.summary.contains("checked 1 of them"))
        XCTAssertTrue(completion.summary.contains("can’t tell whether the last step"))
        XCTAssertTrue(completion.summary.contains("didn’t touch the rest"))
        XCTAssertTrue(completion.summary.contains("try again"))
    }

    private func execution(
        stepEvidence: [ExecutionStepEvidence] = [
            ExecutionStepEvidence(id: "first", summary: "Rename the file"),
            ExecutionStepEvidence(id: "second", summary: "Rename the file"),
        ],
        verificationEvidence: [ExecutionVerificationEvidence]? = nil
    ) -> ExecutionSessionState {
        ExecutionSessionState(
            taskID: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            goal: "Rename two files",
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            appBundleID: "com.apple.finder",
            workspace: URL(fileURLWithPath: "/tmp/perry-execution-finalizer-tests"),
            lifecycle: .finalizing(.verifying),
            stepEvidence: stepEvidence,
            verificationEvidence: verificationEvidence ?? [
                ExecutionVerificationEvidence(stepID: "first", verified: true, warning: nil),
                ExecutionVerificationEvidence(stepID: "second", verified: true, warning: nil),
            ],
            totalSteps: 2
        )
    }
}

private actor RecordingExecutionNotifier: Notifying {
    private var notifications: [TaskNotification] = []

    func deliver(_ notification: TaskNotification) {
        notifications.append(notification)
    }

    func snapshot() -> [TaskNotification] {
        notifications
    }
}

private final class RejectingExecutionMoveFileManager: FileManager {
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        throw NSError(domain: "ExecutionFinalizerTests", code: 1)
    }
}
