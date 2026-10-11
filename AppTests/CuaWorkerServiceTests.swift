import XCTest
@testable import Perry

@MainActor
final class CuaWorkerServiceTests: XCTestCase {
    func testThreeBackgroundOperationsAreParkedAndFourthReachesCapacityWithoutInvocation() async throws {
        let service = CuaWorkerService()
        let started = expectation(description: "background workers started")
        started.expectedFulfillmentCount = 3
        var workers: [Task<Void, Error>] = []

        for _ in 0..<3 {
            workers.append(Task {
                try await service.withWorker(scope: .background, resources: []) { _ in
                    started.fulfill()
                    try await Task.sleep(for: .seconds(10))
                }
            })
        }
        let parkedTasks = workers
        addTeardownBlock { parkedTasks.forEach { $0.cancel() } }

        let startedResult = await XCTWaiter.fulfillment(of: [started], timeout: 1)
        XCTAssertEqual(startedResult, .completed)
        do {
            _ = try await service.withWorker(scope: .background, resources: []) { _ in
                XCTFail("Fourth worker operation was invoked")
            }
            XCTFail("capacity should reject the fourth worker")
        } catch let error as CuaWorkerError {
            XCTAssertEqual(error, .capacityReached)
        }

        for worker in workers {
            worker.cancel()
            let result = await finish(worker)
            assertCancellation(result)
        }
    }

    func testConflictingApplicationClaimsBlockInitialAndDynamicClaims() async throws {
        let service = CuaWorkerService()
        let resource: Set<BackgroundTaskResource> = [.application("com.example.Editor")]
        let parked = parkedWorker(service: service, resources: resource)
        addTeardownBlock { parked.task.cancel() }
        let parkedStartedResult = await XCTWaiter.fulfillment(of: [parked.started], timeout: 1)
        XCTAssertEqual(parkedStartedResult, .completed)

        do {
            _ = try await service.withWorker(scope: .background, resources: resource) { _ in
                XCTFail("conflicting initial claim should not invoke the operation")
            }
            XCTFail("conflicting initial claim should fail")
        } catch let error as CuaWorkerError {
            XCTAssertEqual(error, .resourceBusy)
        }

        parked.task.cancel()
        assertCancellation(await finish(parked.task))

        let secondParked = parkedWorker(service: service, resources: resource)
        addTeardownBlock { secondParked.task.cancel() }
        let secondParkedStartedResult = await XCTWaiter.fulfillment(of: [secondParked.started], timeout: 1)
        XCTAssertEqual(secondParkedStartedResult, .completed)
        let dynamic = try await service.withWorker(scope: .background, resources: []) { handle in
            do {
                try await handle.claimResources([.application("com.example.editor")])
                return false
            } catch let error as CuaWorkerError {
                return error == .resourceBusy
            }
        }
        XCTAssertTrue(dynamic)
        secondParked.task.cancel()
        assertCancellation(await finish(secondParked.task))
    }

    func testWorkspaceClaimsBlockAncestorsAndDescendantsButPermitSiblings() async throws {
        let service = CuaWorkerService()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("perry-claims-\(UUID())")
        let workspace = root.appendingPathComponent("task")
        try await service.withWorker(scope: .foreground, resources: [.workspace(workspace.path)]) { _ in
            for conflict in [root, workspace.appendingPathComponent("output")] {
                do {
                    try await service.withWorker(scope: .background, resources: [.workspace(conflict.path)]) { _ in
                        XCTFail("An overlapping workspace entered its operation")
                    }
                    XCTFail("An overlapping workspace was admitted")
                } catch let error as CuaWorkerError {
                    XCTAssertEqual(error, .resourceBusy)
                }
            }
            let sibling = root.appendingPathComponent("task-2")
            let entered = try await service.withWorker(scope: .background, resources: [.workspace(sibling.path)]) { _ in
                true
            }
            XCTAssertTrue(entered)
        }
        let reclaimed = try await service.withWorker(scope: .background, resources: [.workspace(root.path)]) { _ in
            true
        }
        XCTAssertTrue(reclaimed)
    }

    func testCanceledSetupCancelsOperationBeforeClaimRelease() async throws {
        let service = CuaWorkerService()
        let resource: Set<BackgroundTaskResource> = [.integration("mail")]
        let entered = expectation(description: "setup entered")
        let task = Task {
            try await service.withWorker(scope: .background, resources: resource) { _ in
                entered.fulfill()
                try await Task.sleep(for: .seconds(10))
            }
        }
        addTeardownBlock { task.cancel() }
        let enteredResult = await XCTWaiter.fulfillment(of: [entered], timeout: 1)
        XCTAssertEqual(enteredResult, .completed)
        task.cancel()
        assertCancellation(await finish(task))

        let replacement = try await service.withWorker(scope: .background, resources: resource) { _ in
            return true
        }
        XCTAssertTrue(replacement)
    }

    func testOldHandleRejectsClaimAfterReturn() async throws {
        let service = CuaWorkerService()
        let handle = try await service.withWorker(scope: .background, resources: []) { handle in
            handle
        }

        do {
            try await handle.claimResources([.workspace("/tmp/perry-worker-service")])
            XCTFail("retired handle should not claim resources")
        } catch let error as CuaWorkerError {
            XCTAssertEqual(error, .retired)
        }
    }

    func testWithWorkersStoppedBlocksAdmissionDuringClosureAndReopensAfter() async throws {
        let service = CuaWorkerService()
        let parked = parkedWorker(service: service, resources: [])
        addTeardownBlock { parked.task.cancel() }
        let parkedStartedResult = await XCTWaiter.fulfillment(of: [parked.started], timeout: 1)
        XCTAssertEqual(parkedStartedResult, .completed)
        let closureEntered = expectation(description: "maintenance entered")
        let closureGate = TestContinuationGate()
        let maintenance = Task {
            try await service.withWorkersStopped {
                closureEntered.fulfill()
                await closureGate.wait()
            }
        }
        addTeardownBlock {
            maintenance.cancel()
            await closureGate.release()
            parked.task.cancel()
        }
        let closureEnteredResult = await XCTWaiter.fulfillment(of: [closureEntered], timeout: 1)
        XCTAssertEqual(closureEnteredResult, .completed)

        do {
            _ = try await service.withWorker(scope: .background, resources: []) { _ in
                XCTFail("admission should be closed during maintenance")
            }
            XCTFail("admission should be closed during maintenance")
        } catch let error as CuaWorkerError {
            XCTAssertEqual(error, .admissionClosed)
        }

        await closureGate.release()
        assertSuccess(await finish(maintenance))
        let reopened = try await service.withWorker(scope: .background, resources: []) { _ in
            return true
        }
        XCTAssertTrue(reopened)
    }

    func testCancelledMaintenanceKeepsAdmissionClosedUntilItsOperationFinishes() async throws {
        let service = CuaWorkerService()
        let entered = expectation(description: "maintenance entered")
        let gate = TestContinuationGate()
        let maintenance = Task {
            try await service.withWorkersStopped {
                entered.fulfill()
                await gate.wait()
                XCTAssertTrue(Task.isCancelled, "Maintenance did not receive caller cancellation")
            }
        }
        addTeardownBlock {
            maintenance.cancel()
            await gate.release()
        }
        let enteredResult = await XCTWaiter.fulfillment(of: [entered], timeout: 1)
        XCTAssertEqual(enteredResult, .completed)
        maintenance.cancel()
        do {
            try await service.withWorker(scope: .background, resources: []) { _ in
                XCTFail("A worker entered while cancelled maintenance was still running")
            }
            XCTFail("Admission reopened before maintenance finished")
        } catch let error as CuaWorkerError {
            XCTAssertEqual(error, .admissionClosed)
        }
        await gate.release()
        assertCancellation(await finish(maintenance))
        let reopened = try await service.withWorker(scope: .background, resources: []) { _ in true }
        XCTAssertTrue(reopened)
    }

    func testMaintenanceInvokedInsideWorkerRejects() async throws {
        let service = CuaWorkerService()
        let result = try await service.withWorker(scope: .background, resources: []) { _ in
            do {
                _ = try await service.withWorkersStopped { true }
                return false
            } catch let error as CuaWorkerError {
                return error == .maintenanceInsideWorker
            }
        }
        XCTAssertTrue(result)
    }

    func testUncooperativeOperationSurfacesStopFailureButFreesClaims() async throws {
        let service = CuaWorkerService()
        let resource: Set<BackgroundTaskResource> = [.application("com.example.Uncooperative")]
        let started = expectation(description: "uncooperative operation started")
        let gate = TestContinuationGate()
        let task = Task {
            try await service.withWorker(scope: .background, resources: resource) { _ in
                started.fulfill()
                await gate.wait()
            }
        }
        addTeardownBlock { task.cancel(); await gate.release() }
        let startedResult = await XCTWaiter.fulfillment(of: [started], timeout: 1)
        XCTAssertEqual(startedResult, .completed)
        task.cancel()

        assertFailure(await finish(task), equals: .operationDidNotStop)

        // The retired worker's driver is dead, so its claims are pure wedge;
        // a new worker must be admitted on the same resource.
        let reclaimed = try await service.withWorker(scope: .background, resources: resource) { _ in
            return true
        }
        XCTAssertTrue(reclaimed)
        await gate.release()
        _ = await finish(task)
    }

    func testMaintenanceCanRetryAfterAnUncooperativeOperationFinishes() async throws {
        let service = CuaWorkerService()
        let entered = expectation(description: "operation entered")
        let gate = TestContinuationGate()
        let task = Task {
            try await service.withWorker(scope: .background, resources: [.integration("mail")]) { _ in
                entered.fulfill()
                await gate.wait()
            }
        }
        addTeardownBlock {
            task.cancel()
            await gate.release()
        }
        let enteredResult = await XCTWaiter.fulfillment(of: [entered], timeout: 1)
        XCTAssertEqual(enteredResult, .completed)
        do {
            try await service.withWorkersStopped { XCTFail("Maintenance ran before the operation stopped") }
            XCTFail("Unconfirmed stop was accepted")
        } catch let error as CuaWorkerError {
            XCTAssertEqual(error, .operationDidNotStop)
        }
        do {
            try await service.withWorker(scope: .health, resources: []) { _ in
                XCTFail("A worker started while maintenance was blocked")
            }
            XCTFail("Admission reopened after a failed stop")
        } catch let error as CuaWorkerError {
            XCTAssertEqual(error, .admissionClosed)
        }
        await gate.release()
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while ContinuousClock.now < deadline {
            do {
                try await service.withWorkersStopped {}
                let resumed = try await service.withWorker(scope: .background, resources: [.integration("mail")]) { _ in true }
                XCTAssertTrue(resumed)
                return
            } catch CuaWorkerError.operationDidNotStop {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        XCTFail("Maintenance could not recover after the operation completed")
    }

    func testShutdownWaitsForEnteredMaintenanceAndNeverReopensAdmission() async throws {
        let service = CuaWorkerService()
        let entered = expectation(description: "maintenance entered")
        let gate = TestContinuationGate()
        let maintenance = Task {
            try await service.withWorkersStopped {
                entered.fulfill()
                await gate.wait()
            }
        }
        addTeardownBlock {
            maintenance.cancel()
            await gate.release()
        }
        let enteredResult = await XCTWaiter.fulfillment(of: [entered], timeout: 1)
        XCTAssertEqual(enteredResult, .completed)
        let returnedEarly = expectation(description: "shutdown returned before maintenance finished")
        returnedEarly.isInverted = true
        let shutdown = Task {
            try await service.shutdown()
            returnedEarly.fulfill()
        }
        let earlyResult = await XCTWaiter.fulfillment(of: [returnedEarly], timeout: 0.05)
        XCTAssertEqual(earlyResult, .completed)
        await gate.release()
        assertSuccess(await finish(maintenance))
        assertSuccess(await finish(shutdown))
        do {
            try await service.withWorker(scope: .background, resources: []) { _ in
                XCTFail("Shutdown reopened worker admission")
            }
            XCTFail("Shutdown accepted a new worker")
        } catch let error as CuaWorkerError {
            XCTAssertEqual(error, .admissionClosed)
        }
    }

    func testRetiredWorkerCannotReportSuccessAfterIgnoringCancellation() async {
        let service = CuaWorkerService()
        let task = Task {
            try await service.withWorker(scope: .background, resources: []) { worker in
                try await worker.retire()
            }
        }
        addTeardownBlock { task.cancel() }
        assertCancellation(await finish(task))
    }

    func testMaintenanceCannotAwaitItsOwnShutdown() async throws {
        let service = CuaWorkerService()
        let rejected = try await service.withWorkersStopped {
            do {
                try await service.shutdown()
                return false
            } catch let error as CuaWorkerError {
                return error == .maintenanceInsideWorker
            }
        }
        XCTAssertTrue(rejected)
    }

    private func parkedWorker(
        service: CuaWorkerService,
        resources: Set<BackgroundTaskResource>
    ) -> (task: Task<Void, Error>, started: XCTestExpectation) {
        let started = expectation(description: "worker started")
        let task = Task {
            try await service.withWorker(scope: .background, resources: resources) { _ in
                started.fulfill()
                try await Task.sleep(for: .seconds(10))
            }
        }
        return (task, started)
    }

    private func finish(_ task: Task<Void, Error>) async -> Result<Void, Error> {
        let completed = expectation(description: "task completed")
        let waiter = Task {
            let result = await task.result
            completed.fulfill()
            return result
        }
        let completionResult = await XCTWaiter.fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(completionResult, .completed)
        guard completionResult == .completed else {
            return .failure(CuaWorkerTestError.timeout)
        }
        return await waiter.value
    }

    private func assertCancellation(_ result: Result<Void, Error>) {
        guard case .failure(let error) = result else {
            XCTFail("expected CancellationError")
            return
        }
        XCTAssertTrue(error is CancellationError, "unexpected error: \(error)")
    }

    private func assertSuccess(_ result: Result<Void, Error>) {
        guard case .success = result else {
            XCTFail("unexpected task failure: \(String(describing: result))")
            return
        }
    }

    private func assertFailure(_ result: Result<Void, Error>, equals expected: CuaWorkerError) {
        guard case .failure(let error) = result else {
            XCTFail("expected \(expected)")
            return
        }
        XCTAssertEqual(error as? CuaWorkerError, expected)
    }
}

private enum CuaWorkerTestError: Error {
    case timeout
}

private actor TestContinuationGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}
