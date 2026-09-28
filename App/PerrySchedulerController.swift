import CoreGraphics
import Foundation
import Network
import PerryBrain

/// Phase 9: fires scheduled Perrys. A 60-second tick evaluates
/// `RoutineDecisions.shouldRun` for each Perry's schedule — due routines run
/// the Perry's job as an agent turn on its bound thread, and the outcome is
/// recorded back (missed slots catch up on the next tick, failures back off
/// after three consecutive misses). The store's Perry list is republished on
/// every tick so Home's sidebar stays current.
@MainActor
final class PerrySchedulerController {
    private let store: PerryStore
    private let coordinator: AgentCoordinator
    /// A foreground Do run owns the user's attention — scheduled work waits.
    private let isBusy: @MainActor () -> Bool
    /// Republished every tick (and once at start) so Home's sidebar sees
    /// Perry creates/removes without reopening the window.
    var onPerrysChanged: (@MainActor ([Perry]) -> Void)?

    private var timer: Timer?
    private var runningPerryIDs: Set<UUID> = []
    private let networkMonitor = NWPathMonitor()
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
        networkMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.hasNetwork = path.status == .satisfied
            }
        }
        networkMonitor.start(queue: .global(qos: .utility))
        // ponytail: a repeating Timer can be coalesced under App Nap while
        // Perry is idle — an overdue slot still runs on the first post-wake
        // tick (RoutineDecisions.isDue stays due until recorded).
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.tick() }
        }
        Task { await tick() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        networkMonitor.cancel()
    }

    private var sessionIsUnlocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        // kCGSSessionScreenIsLocked isn't exported to Swift — the key itself
        // has been stable since 10.6.
        return (session["CGSSessionScreenIsLocked"] as? Bool) != true
    }

    private func tick() async {
        let perrys = await store.list()
        onPerrysChanged?(perrys)
        let now = Date()
        let awake = sessionIsUnlocked
        let network = hasNetwork
        for perry in perrys {
            guard let schedule = perry.schedule,
                  RoutineDecisions.shouldRun(schedule, now: now, isAwake: awake, hasNetwork: network),
                  !isBusy(),
                  !runningPerryIDs.contains(perry.id),
                  let threadID = UUID(uuidString: perry.threadID)
            else { continue }
            runningPerryIDs.insert(perry.id)
            Task { [weak self] in
                defer { self?.runningPerryIDs.remove(perry.id) }
                var succeeded = false
                for await event in coordinator.run(
                    threadID: threadID,
                    goal: perry.job,
                    perryID: perry.id.uuidString
                ) {
                    if case .finished(.completed) = event { succeeded = true }
                }
                var updated = perry
                updated.schedule = RoutineDecisions.record(schedule, succeeded: succeeded, ranAt: Date())
                try? await store.update(updated)
            }
        }
    }
}
