import XCTest
import PerryCore
import PerryGuide
import PerryRuntimes
@testable import Perry

final class ExecutionFinalizerTests: XCTestCase {
    private let finishedAt = Date(timeIntervalSince1970: 1_800_000_100)

    func testFinalizationPersistsCompletionAndEmitsSideEffects() async throws {
        let directory = try makeDirectory()
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
        let directory = try makeDirectory()
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
        XCTAssertEqual(completion.summary, "Finished 2 steps.")
        XCTAssertEqual(completion.transcript.verified, true)
        XCTAssertEqual(completion.notification.kind, .completed)
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

        XCTAssertTrue(completion.summary.contains("nothing was changed"))
        XCTAssertTrue(completion.summary.contains("Safe next step"))
    }

    func testFailedSummaryReportsPartialProgressUncertaintyAndNextStep() {
        let completion = ExecutionFinalizer.completion(
            execution: execution(verificationEvidence: [
                ExecutionVerificationEvidence(stepID: "first", verified: true, warning: nil),
            ]),
            outcome: .failed(stepSummary: "Rename the file", reason: "read-back failed"),
            finishedAt: finishedAt
        )

        XCTAssertTrue(completion.summary.contains("1 verified"))
        XCTAssertTrue(completion.summary.contains("uncertain"))
        XCTAssertTrue(completion.summary.contains("left untouched"))
        XCTAssertTrue(completion.summary.contains("Safe next step"))
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

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-execution-finalizer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try FileManager.default.removeItem(at: directory)
        }
        return directory
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
