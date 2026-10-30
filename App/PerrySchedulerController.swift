import CoreGraphics
import Foundation
import Network
import PerryBrain

@MainActor
final class PerrySchedulerController {
    private let store: PerryStore
    private let coordinator: AgentCoordinator
    private let isBusy: @MainActor () -> Bool
    var onPerrysChanged: (@MainActor ([Perry]) -> Void)?

    private var timer: Timer?
    private var tickTask: Task<Void, Never>?
    private var runs: [UUID: Task<Void, Never>] = [:]
    private var networkMonitor = NWPathMonitor()
    private var hasNetwork = true

    init(
        store: PerryStore,
        coordinator: AgentCoordinator,
        isBusy: @escaping @MainActor () -> Bool
    ) {
        self.store = store
        self.coordinator = coordinator
        self.isBusy = isBusy
    }

    func start() {
        guard timer == nil else { return }
        networkMonitor = NWPathMonitor()
        networkMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.hasNetwork = path.status == .satisfied
            }
        }
        networkMonitor.start(queue: .global(qos: .utility))
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.requestTick() }
        }
        requestTick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        networkMonitor.cancel()
        tickTask?.cancel()
        for task in runs.values { task.cancel() }
    }

    func joinAll() async {
        await tickTask?.value
        for task in runs.values { await task.value }
    }

    private func requestTick() {
        guard timer != nil, tickTask == nil else { return }
        tickTask = Task {
            defer { tickTask = nil }
            await tick(now: Date(), awake: sessionIsUnlocked, network: hasNetwork)
        }
    }

    private var sessionIsUnlocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        // kCGSSessionScreenIsLocked isn't exported to Swift
        return (session["CGSSessionScreenIsLocked"] as? Bool) != true
    }

    func tick(now: Date, awake: Bool, network: Bool) async {
        let perrys = await store.list()
        guard !Task.isCancelled, timer != nil else { return }
        onPerrysChanged?(perrys)
        for perry in perrys {
            guard let schedule = perry.schedule,
                  RoutineDecisions.shouldRun(schedule, now: now, isAwake: awake, hasNetwork: network),
                  !isBusy(),
                  runs[perry.id] == nil,
                  let threadID = UUID(uuidString: perry.threadID)
            else { continue }
            runs[perry.id] = Task {
                defer { runs[perry.id] = nil }
                let result = await coordinator.runToEnd(
                    threadID: threadID,
                    goal: perry.job,
                    kind: .unattended(perryID: perry.id.uuidString)
                )
                let succeeded = result.finish == .completed
                var updated = perry
                updated.schedule = RoutineDecisions.record(schedule, succeeded: succeeded, ranAt: Date())
                try? await store.update(updated)
            }
        }
    }
}
