import Foundation
import XCTest
import PerryCore
import PerryGuide
import PerryRuntimes
@testable import Perry

@MainActor
final class WorkerFinalizationTests: XCTestCase {
    func testMaintenanceWaitsForFinalizationBeforeErasingPersistedStores() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-worker-finalization-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try TestTempDirectory.remove(directory) }

        let transcriptStore = TranscriptStore(directory: directory)
        let memoryStore = MemoryStore(
            storageDirectory: directory,
            configuration: MemoryConfiguration(enabled: true)
        )
        let notifierEntered = expectation(description: "finalization reached notification")
        let finalizationFinished = expectation(description: "finalization returned")
        let notifier = FinalizationNotifier(onEntered: { notifierEntered.fulfill() })
        let finalizer = ExecutionFinalizer(
            transcriptStore: transcriptStore,
            memoryStore: memoryStore,
            notifier: notifier
        )
        let taskCoordinator = TaskCoordinator(storageDirectory: directory)
        let backgroundTaskContextStore = BackgroundTaskContextStore(storageDirectory: directory)
        let activityLog = ActivityLog(storageDirectory: directory)
        let paths = PerryErasurePaths(
            supportDirectory: directory,
            homeDirectory: directory.appendingPathComponent("Home", isDirectory: true),
            temporaryDirectory: directory.appendingPathComponent("Temporary", isDirectory: true),
            cachesDirectory: directory.appendingPathComponent("Caches", isDirectory: true)
        )
        let erasers = PerryLiveErasureErasers.make(
            paths: paths,
            taskCoordinator: taskCoordinator,
            backgroundTaskContextStore: backgroundTaskContextStore,
            activityLog: activityLog,
            transcriptStore: transcriptStore,
            memoryStore: memoryStore
        )
        let historyEraser = try XCTUnwrap(erasers.first { $0.category == .history })
        let memoryEraser = try XCTUnwrap(erasers.first { $0.category == .memory })
        let erasure = CompleteErasureCoordinator(erasers: [historyEraser, memoryEraser])
        let service = CuaWorkerService()
        let taskID = UUID(uuidString: "00000000-0000-0000-0000-000000000202")!
        let categories: Set<PerryErasureCategory> = [.history, .memory]
        let workerTask = Task {
            try await service.withWorker(scope: .background, resources: []) { _ in
                _ = await finalizer.finalize(
                    execution: ExecutionSessionState(
                        taskID: taskID,
                        goal: "Rename one file",
                        startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                        appBundleID: "com.apple.finder",
                        workspace: directory,
                        lifecycle: .finalizing(.verifying),
                        stepEvidence: [ExecutionStepEvidence(id: "step", summary: "Rename one file")],
                        verificationEvidence: [
                            ExecutionVerificationEvidence(stepID: "step", verified: true, warning: nil),
                        ],
                        totalSteps: 1
                    ),
                    outcome: .completed(stepsRun: 1),
                    finishedAt: Date(timeIntervalSince1970: 1_800_000_001)
                )
                finalizationFinished.fulfill()
            }
        }
        addTeardownBlock {
            workerTask.cancel()
            await notifier.release()
            _ = await self.finish(workerTask)
        }

        let notifierResult = await XCTWaiter.fulfillment(of: [notifierEntered], timeout: 1)
        XCTAssertEqual(notifierResult, .completed)
        guard notifierResult == .completed else { return }

        do {
            _ = try await service.withWorkersStopped {
                await erasure.erase(categories: categories)
            }
            XCTFail("maintenance erased stores before finalization returned")
        } catch let error as CuaWorkerError {
            XCTAssertEqual(error, .operationDidNotStop)
        } catch {
            XCTFail("unexpected maintenance failure: \(error)")
        }

        let persistedTranscripts = await transcriptStore.snapshot()
        XCTAssertEqual(persistedTranscripts.map(\.id), [taskID])
        XCTAssertEqual(persistedTranscripts.first?.summary, "Done. I ran 1 step.")
        let reloadedTranscriptStore = TranscriptStore(directory: directory)
        let reloadedTranscripts = await reloadedTranscriptStore.snapshot()
        XCTAssertEqual(reloadedTranscripts.map(\.id), [taskID])
        let persistedMemories = await memoryStore.snapshot()
        XCTAssertEqual(persistedMemories.map(\.summary), ["Done. I ran 1 step."])

        await notifier.release()
        let finalizationResult = await XCTWaiter.fulfillment(of: [finalizationFinished], timeout: 1)
        XCTAssertEqual(finalizationResult, .completed)
        guard finalizationResult == .completed else { return }

        let workerResult = await finish(workerTask)
        guard case .failure(let workerError) = workerResult else {
            return XCTFail("worker unexpectedly reported success after stop failure")
        }
        XCTAssertEqual(workerError as? CuaWorkerError, .operationDidNotStop)

        let report = try await service.withWorkersStopped {
            await erasure.erase(categories: categories)
        }
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertTrue(report.postEraseInventory.items.isEmpty)
        let postEraseInventory = await erasure.inventory(categories: categories)
        XCTAssertTrue(postEraseInventory.items.isEmpty)
        let erasedTranscripts = await transcriptStore.snapshot()
        XCTAssertTrue(erasedTranscripts.isEmpty)
        let erasedMemories = await memoryStore.snapshot()
        XCTAssertTrue(erasedMemories.isEmpty)
    }

    private func finish(_ task: Task<Void, Error>) async -> Result<Void, Error> {
        let completed = expectation(description: "worker task completed")
        let waiter = Task {
            let result = await task.result
            completed.fulfill()
            return result
        }
        let waitResult = await XCTWaiter.fulfillment(of: [completed], timeout: 1)
        guard waitResult == .completed else {
            XCTFail("worker task did not complete within the timeout")
            return .failure(WorkerFinalizationTestError.timeout)
        }
        return await waiter.value
    }
}

private actor FinalizationNotifier: Notifying {
    private let onEntered: @Sendable () -> Void
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    init(onEntered: @escaping @Sendable () -> Void) {
        self.onEntered = onEntered
    }

    func deliver(_ notification: TaskNotification) async {
        onEntered()
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private enum WorkerFinalizationTestError: Error {
    case timeout
}
