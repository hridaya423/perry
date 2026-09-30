import Foundation
import PerryRuntimes

final class ForegroundWorkerLease: @unchecked Sendable {
    private let lock = NSLock()
    private var handles: [UUID: CuaWorkerHandle] = [:]

    func withRun<Value: Sendable>(
        _ runID: UUID,
        workers: CuaWorkerService,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        if worker(for: runID) != nil { return try await operation() }
        return try await workers.withWorker(scope: .background, resources: []) { worker in
            self.set(worker, for: runID)
            defer { self.set(nil, for: runID) }
            return try await operation()
        }
    }

    func worker(for runID: UUID) -> CuaWorkerHandle? {
        lock.lock()
        defer { lock.unlock() }
        return handles[runID]
    }

    func set(_ handle: CuaWorkerHandle?, for runID: UUID) {
        lock.lock()
        handles[runID] = handle
        lock.unlock()
    }
}

func withCuaWorker<Value: Sendable>(
    _ workers: CuaWorkerService,
    lease: ForegroundWorkerLease?,
    runID: UUID,
    resources: Set<BackgroundTaskResource>,
    _ body: @escaping @Sendable (CuaWorkerHandle) async throws -> Value
) async throws -> Value {
    try Task.checkCancellation()
    if let lent = lease?.worker(for: runID) {
        try await lent.claimResources(resources)
        return try await body(lent)
    }
    return try await workers.withWorker(scope: .background, resources: resources, operation: body)
}
