import Foundation
import PerryRuntimes

struct ToolWorkerContext: Sendable {
    let workers: ScreenWorkerService
    let lease: ForegroundWorkerLease?
    let observations: AgentObservationStore

    func withWorker<Value: Sendable>(
        runID: UUID,
        resources: Set<BackgroundTaskResource> = [],
        _ body: @escaping @Sendable (ScreenWorkerHandle) async throws -> Value
    ) async throws -> Value {
        try await withScreenWorker(workers, lease: lease, runID: runID, resources: resources, body)
    }
}
