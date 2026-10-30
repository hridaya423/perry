import Foundation
import PerryRuntimes

@MainActor
protocol RunHandle: AnyObject {
    var continuesInPlace: Bool { get }
    func pause()
    func resume()
    func steer(_ instruction: String)
    @discardableResult func stop() -> Task<Void, Never>
}

@MainActor
final class AgentRunHandle: RunHandle {
    let continuesInPlace = true
    private let coordinator: AgentCoordinator
    private let threadID: UUID

    init(coordinator: AgentCoordinator, threadID: UUID) {
        self.coordinator = coordinator
        self.threadID = threadID
    }

    func pause() { coordinator.pause(threadID: threadID) }
    func resume() { coordinator.resume(threadID: threadID) }
    func steer(_ instruction: String) { coordinator.steer(instruction, threadID: threadID) }
    func stop() -> Task<Void, Never> {
        coordinator.stop(threadID: threadID)
        return Task {}
    }
}

@MainActor
final class SupervisorRunHandle: RunHandle {
    let continuesInPlace = false
    private let supervisor: DoSupervisor

    init(supervisor: DoSupervisor) {
        self.supervisor = supervisor
    }

    func pause() { Task { await supervisor.pause() } }
    func resume() { Task { await supervisor.resume() } }
    func steer(_ instruction: String) { Task { await supervisor.steer(instruction) } }
    func stop() -> Task<Void, Never> { Task { await supervisor.cancel() } }
}
