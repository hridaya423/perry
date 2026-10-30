import Foundation
import PerryRuntimes

struct ToolWorkerContext: Sendable {
    let workers: CuaWorkerService
    let lease: ForegroundWorkerLease?
    let observations: AgentObservationStore

    func withWorker<Value: Sendable>(
        runID: UUID,
        resources: Set<BackgroundTaskResource> = [],
        _ body: @escaping @Sendable (CuaWorkerHandle) async throws -> Value
    ) async throws -> Value {
        try await withCuaWorker(workers, lease: lease, runID: runID, resources: resources, body)
    }
}
