import Foundation

@MainActor
final class BackgroundTaskControlScope {
    enum DrainError: Error {
        case timedOut
    }

    enum Admission {
        case open
        case draining
        case closed
        case reopening
    }

    private(set) var admission: Admission = .open
    private var tasks: [UUID: Task<Void, Never>] = [:]

    var acceptsControls: Bool {
        admission == .open
    }

    @discardableResult
    func start(_ operation: @escaping @MainActor () async -> Void) -> Bool {
        guard admission == .open else { return false }
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            defer {
                if let self {
                    self.tasks[id] = nil
                    if self.tasks.isEmpty, self.admission == .reopening {
                        self.admission = .open
                    }
                }
            }
            await operation()
        }
        tasks[id] = task
        return true
    }

    func close() {
        guard admission == .open || admission == .reopening else { return }
        admission = .draining
    }

    func closeAndDrain() async throws {
        close()
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
        while !tasks.isEmpty {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw DrainError.timedOut }
            try await Task.sleep(
                until: min(deadline, ContinuousClock.now.advanced(by: .milliseconds(5))),
                clock: .continuous
            )
        }
        if admission == .draining {
            admission = .closed
        }
    }

    func reopen() {
        guard admission != .open else { return }
        admission = tasks.isEmpty ? .open : .reopening
    }
}
