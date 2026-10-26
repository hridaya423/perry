import Combine

@MainActor
final class RuntimeSettingsState: ObservableObject {
    struct Status: Equatable {
        let setup: RuntimeSetupSnapshot
        let cuaStatus: String
    }

    @Published private(set) var status = Status(
        setup: RuntimeSetupSnapshot(summary: "Looking for coding agents…", records: []),
        cuaStatus: "Checking…"
    )

    private let load: @MainActor () async -> Status
    private var refreshTask: Task<Void, Never>?

    init(load: @escaping @MainActor () async -> Status) {
        self.load = load
    }

    @discardableResult
    func refresh() -> Task<Void, Never> {
        cancel()
        let task = Task { @MainActor [weak self, load] in
            guard !Task.isCancelled else { return }
            let status = await load()
            guard !Task.isCancelled else { return }
            self?.status = status
        }
        refreshTask = task
        return task
    }

    func cancel() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    deinit {
        refreshTask?.cancel()
    }
}
