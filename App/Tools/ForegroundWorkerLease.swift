import ApplicationServices
import CoreGraphics
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
    let explained: @Sendable (CuaWorkerHandle) async throws -> Value = { worker in
        do {
            return try await body(worker)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ComputerUseAccessError.missing() ?? error
        }
    }
    if let lent = lease?.worker(for: runID) {
        try await lent.claimResources(resources)
        return try await explained(lent)
    }
    return try await workers.withWorker(scope: .background, resources: resources, operation: explained)
}

struct ComputerUseAccessError: LocalizedError {
    let missing: [String]

    static func missing() -> ComputerUseAccessError? {
        var missing: [String] = []
        if !AXIsProcessTrusted() { missing.append("Accessibility") }
        if !CGPreflightScreenCaptureAccess() { missing.append("Screen Recording") }
        return missing.isEmpty ? nil : ComputerUseAccessError(missing: missing)
    }

    var errorDescription: String? {
        "Perry can’t see or use other apps because \(missing.joined(separator: " and ")) is off for Perry. "
            + "Tell the user to turn it on in Settings › General › Permissions, then try again."
    }
}
