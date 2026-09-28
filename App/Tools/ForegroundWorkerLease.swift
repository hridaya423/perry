import Foundation
import PerryRuntimes

/// While a foreground Do run drives the agent loop, its already-claimed
/// worker is lent to screen/ui tools so they share the session's target-app
/// lock instead of claiming a conflicting `.application` resource on a
/// background worker.
final class ForegroundWorkerLease: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: CuaWorkerHandle?

    var current: CuaWorkerHandle? {
        lock.lock()
        defer { lock.unlock() }
        return handle
    }

    func set(_ handle: CuaWorkerHandle?) {
        lock.lock()
        self.handle = handle
        lock.unlock()
    }
}

/// Runs `body` on the lent foreground worker when one is active, else claims
/// a background worker as usual.
func withCuaWorker<Value: Sendable>(
    _ workers: CuaWorkerService,
    lease: ForegroundWorkerLease?,
    resources: Set<BackgroundTaskResource>,
    _ body: @escaping @Sendable (CuaWorkerHandle) async throws -> Value
) async throws -> Value {
    if let lent = lease?.current { return try await body(lent) }
    return try await workers.withWorker(scope: .background, resources: resources, operation: body)
}
