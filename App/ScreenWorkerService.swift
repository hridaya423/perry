import Foundation
import PerryGuide
import PerryRuntimes

enum ScreenWorkerScope: Hashable, Sendable {
    case background, foreground, guide, dictation, health

    var capacity: Int { self == .background ? 3 : 1 }
}

enum ScreenWorkerError: Error, Equatable, LocalizedError {
    case admissionClosed
    case capacityReached
    case resourceBusy
    case retired
    case operationDidNotStop
    case maintenanceInsideWorker

    var errorDescription: String? {
        switch self {
        case .admissionClosed: "Perry is shutting down and can’t start screen control. Open Perry again to retry."
        case .capacityReached: "Perry is already running as many tasks as it can. Wait for one to finish, or stop one."
        case .resourceBusy: "Another task is using that app. Wait for it to finish, or stop it."
        case .retired: "Screen control for this task already ended. Start the task again."
        case .operationDidNotStop: "Screen control didn’t stop when asked. Quit and reopen Perry."
        case .maintenanceInsideWorker: "Perry can’t restart screen control while a task is using it. Stop the task, then try again."
        }
    }
}

struct ScreenWorkerHandle: Sendable {
    fileprivate let service: ScreenWorkerService
    fileprivate let allocation: UUID

    func capture(target: ScreenTargetHint?, includeScreenshot: Bool = true) async throws -> ScreenCapturedWindow {
        try await service.capture(target: target, includeScreenshot: includeScreenshot, allocation: allocation)
    }

    func execute(_ action: ComputerAction) async throws -> StepResult {
        try await service.execute(action, allocation: allocation)
    }

    func insertText(_ text: String, target: ScreenTargetHint) async throws -> ScreenWindowTarget {
        try await service.insertText(text, target: target, allocation: allocation)
    }

    func probeTarget(_ target: ScreenTargetHint?) async throws -> ScreenWindowTarget {
        try await service.probeTarget(target, allocation: allocation)
    }

    func claimResources(_ resources: Set<BackgroundTaskResource>) async throws {
        try await service.claim(resources, allocation: allocation)
    }

    func retire() async throws {
        try await service.retire(allocation)
    }
}

private enum ScreenWorkerContext {
    @TaskLocal static var serviceID: UUID?
}

actor ScreenWorkerService {
    private enum Admission { case accepting, maintenance, blocked, closed }

    private struct Worker {
        let scope: ScreenWorkerScope
        let client: AgentDesktopClient
        var resources: Set<BackgroundTaskResource>
        var cancelOperation: @Sendable () -> Void = {}
        var operationFinished = false
        var waiter: CheckedContinuation<Void, Never>?
        var retirement: Task<Void, Error>?
        var completion: Task<Void, Error>?
        var stopDeadline: ContinuousClock.Instant?
        var droppedActions = 0
    }

    private let serviceID = UUID()
    private let configuration: AgentDesktopConfiguration?
    private var fallbackSource: FallbackSource
    private var admission = Admission.accepting
    private var workers: [UUID: Worker] = [:]
    private var maintenanceCompletion: Task<Void, Never>?

    private enum FallbackSource {
        case discover
        case resolved(CuaDriverConfiguration?)
    }

    init() {
        configuration = nil
        fallbackSource = .discover
    }

    init(configuration: AgentDesktopConfiguration, fallback: CuaDriverConfiguration? = nil) {
        self.configuration = configuration
        fallbackSource = .resolved(fallback)
    }

    private func fallbackConfiguration() -> CuaDriverConfiguration? {
        switch fallbackSource {
        case .discover:
            let discovered = CuaDriverConfiguration.discover()
            fallbackSource = .resolved(discovered)
            return discovered
        case .resolved(let configuration):
            return configuration
        }
    }

    func withWorker<Value: Sendable>(
        scope: ScreenWorkerScope,
        resources: Set<BackgroundTaskResource>,
        operation: @escaping @Sendable (ScreenWorkerHandle) async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        guard admission == .accepting else { throw ScreenWorkerError.admissionClosed }
        guard workers.values.filter({ $0.scope == scope }).count < scope.capacity else {
            throw ScreenWorkerError.capacityReached
        }
        let allocation = UUID()
        let resources = Self.normalized(resources)
        try requireAvailable(resources, excluding: allocation)
        let fallback = fallbackConfiguration().map {
            CuaDriverClient(configuration: $0, allowsRestart: true, allowsForegroundInput: false)
        }
        let client = configuration.map {
            AgentDesktopClient(configuration: $0, allowsRestart: true, allowsForegroundInput: scope == .foreground, fallback: fallback)
        } ?? AgentDesktopClient(allowsRestart: true, allowsForegroundInput: scope == .foreground, fallback: fallback)
        workers[allocation] = Worker(scope: scope, client: client, resources: resources)
        let handle = ScreenWorkerHandle(service: self, allocation: allocation)
        let serviceID = serviceID
        let task = Task {
            let result: Result<Value, Error>
            do {
                let value = try await ScreenWorkerContext.$serviceID.withValue(serviceID) {
                    try Task.checkCancellation()
                    return try await operation(handle)
                }
                try Task.checkCancellation()
                result = .success(value)
            } catch {
                result = .failure(error)
            }
            self.operationFinished(allocation)
            return try result.get()
        }
        workers[allocation]?.cancelOperation = { task.cancel() }
        return try await withTaskCancellationHandler {
            await waitForOperationOrRetirement(allocation)
            try await completeRetirement(allocation).value
            try Task.checkCancellation()
            return try await task.value
        } onCancel: {
            Task { await self.beginRetirement(allocation) }
        }
    }

    func withWorkersStopped<Value: Sendable>(
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try requireOutsideWorker()
        try Task.checkCancellation()
        guard admission == .accepting || admission == .blocked else { throw ScreenWorkerError.admissionClosed }
        admission = .maintenance
        do {
            try await stopWorkers()
        } catch {
            if admission == .maintenance { admission = .blocked }
            throw error
        }
        defer {
            maintenanceCompletion = nil
            if admission == .maintenance { admission = .accepting }
        }
        try Task.checkCancellation()
        guard admission == .maintenance else { throw ScreenWorkerError.admissionClosed }
        let serviceID = serviceID
        let task = Task {
            try await ScreenWorkerContext.$serviceID.withValue(serviceID) {
                try Task.checkCancellation()
                return try await operation()
            }
        }
        maintenanceCompletion = Task { _ = await task.result }
        return try await withTaskCancellationHandler {
            let value = try await task.value
            try Task.checkCancellation()
            return value
        } onCancel: {
            task.cancel()
        }
    }

    func shutdown() async throws {
        try requireOutsideWorker()
        admission = .closed
        try await stopWorkers()
        await maintenanceCompletion?.value
    }

    func reloadConfiguration() async throws {
        try await withWorkersStopped {}
    }

    func health() async -> ScreenDriverHealth {
        do {
            return try await withWorker(scope: .health, resources: []) { handle in
                let client = try await self.client(for: handle.allocation)
                return await client.health()
            }
        } catch {
            return ScreenDriverHealth(ready: false, summary: "Screen control isn’t responding. Try again.")
        }
    }

    fileprivate func claim(_ resources: Set<BackgroundTaskResource>, allocation: UUID) throws {
        try Task.checkCancellation()
        _ = try client(for: allocation)
        let resources = Self.normalized(resources)
        try requireAvailable(resources, excluding: allocation)
        workers[allocation]?.resources.formUnion(resources)
    }

    private static let maxReadRetries = 3

    private func retryingRead<Value>(
        _ allocation: UUID,
        _ read: (AgentDesktopClient) async throws -> Value
    ) async throws -> Value {
        var retriesLeft = Self.maxReadRetries
        while true {
            do {
                return try await read(try client(for: allocation))
            } catch let error as ScreenDriverError where error == .noTargetWindow || error == .appBusy {
                throw error
            } catch let error as ScreenDriverError where error.isRespawnableReadFailure && retriesLeft > 0 {
                retriesLeft -= 1
            } catch {
                beginRetirement(allocation)
                throw error
            }
        }
    }

    fileprivate func capture(target hint: ScreenTargetHint?, includeScreenshot: Bool = true, allocation: UUID) async throws -> ScreenCapturedWindow {
        try await retryingRead(allocation) { client in
            let sessionID = allocation.uuidString
            PerfMark.mark("guide.resolve.begin")
            let target = try await client.resolveTarget(hint, sessionID: sessionID)
            PerfMark.mark("guide.resolve.end")
            try self.claim([.application(target.bundleID)], allocation: allocation)
            PerfMark.mark("guide.state.begin")
            defer { PerfMark.mark("guide.state.end") }
            return try await client.capture(resolvedTarget: target, sessionID: sessionID, includeScreenshot: includeScreenshot)
        }
    }

    fileprivate func probeTarget(_ hint: ScreenTargetHint?, allocation: UUID) async throws -> ScreenWindowTarget {
        try await retryingRead(allocation) { client in
            try await client.resolveTarget(hint, sessionID: allocation.uuidString)
        }
    }

    fileprivate func insertText(_ text: String, target hint: ScreenTargetHint, allocation: UUID) async throws -> ScreenWindowTarget {
        do {
            let client = try client(for: allocation)
            let sessionID = allocation.uuidString
            let target = try await client.resolveTarget(hint, sessionID: sessionID)
            try claim([.application(target.bundleID)], allocation: allocation)
            return try await client.insertText(text, resolvedTarget: target, sessionID: sessionID)
        } catch {
            beginRetirement(allocation)
            throw error
        }
    }

    fileprivate func execute(_ action: ComputerAction, allocation: UUID) async throws -> StepResult {
        do {
            try Task.checkCancellation()
            let client = try client(for: allocation)
            guard let target = await client.target(for: allocation.uuidString) else {
                throw ScreenDriverError.targetNotFound
            }
            try claim([.application(target.bundleID)], allocation: allocation)
            let result = try await client.execute(action, sessionID: allocation.uuidString)
            workers[allocation]?.droppedActions = 0
            return result
        } catch let error as ScreenDriverError where error.isTargetFact {
            throw error
        } catch let error as ScreenDriverError where error.isRespawnableReadFailure
            && (workers[allocation]?.droppedActions ?? Self.maxReadRetries) < Self.maxReadRetries {
            workers[allocation]?.droppedActions += 1
            throw ScreenDriverError.actionUnanswered
        } catch {
            beginRetirement(allocation)
            throw error
        }
    }

    fileprivate func retire(_ allocation: UUID) async throws {
        guard workers[allocation] != nil else { throw ScreenWorkerError.retired }
        try await beginRetirement(allocation).value
    }

    private func client(for allocation: UUID) throws -> AgentDesktopClient {
        guard let worker = workers[allocation], worker.retirement == nil else {
            throw ScreenWorkerError.retired
        }
        return worker.client
    }

    private func operationFinished(_ allocation: UUID) {
        workers[allocation]?.operationFinished = true
        let waiter = workers[allocation]?.waiter
        workers[allocation]?.waiter = nil
        waiter?.resume()
    }

    private func waitForOperationOrRetirement(_ allocation: UUID) async {
        guard let worker = workers[allocation], !worker.operationFinished, worker.retirement == nil else { return }
        await withCheckedContinuation { workers[allocation]?.waiter = $0 }
    }

    @discardableResult
    private func beginRetirement(_ allocation: UUID) -> Task<Void, Error> {
        guard let worker = workers[allocation] else { return Task {} }
        if let retirement = worker.retirement { return retirement }
        let retirement = Task { try await worker.client.retire() }
        workers[allocation]?.stopDeadline = .now.advanced(by: .milliseconds(500))
        workers[allocation]?.retirement = retirement
        worker.cancelOperation()
        workers[allocation]?.waiter = nil
        worker.waiter?.resume()
        return retirement
    }

    private func waitForStoppedOperation(_ allocation: UUID) async throws {
        while let worker = workers[allocation], !worker.operationFinished {
            guard let deadline = worker.stopDeadline, ContinuousClock.now < deadline else {
                throw ScreenWorkerError.operationDidNotStop
            }
            try await Task.sleep(until: min(deadline, ContinuousClock.now.advanced(by: .milliseconds(5))), clock: .continuous)
        }
    }

    private func completeRetirement(_ allocation: UUID) -> Task<Void, Error> {
        if let worker = workers[allocation], let completion = worker.completion, !worker.operationFinished {
            return completion
        }
        let retirement = beginRetirement(allocation)
        let completion = Task {
            defer { self.workers[allocation] = nil }
            let retired = await retirement.result
            try await self.waitForStoppedOperation(allocation)
            if case .failure(let error) = retired, error as? ScreenDriverError != .terminationUnconfirmed {
                throw error
            }
        }
        workers[allocation]?.completion = completion
        return completion
    }

    private func stopWorkers() async throws {
        let completions = workers.keys.map { completeRetirement($0) }
        var firstFailure: Error?
        for completion in completions {
            if case .failure(let error) = await completion.result, firstFailure == nil {
                firstFailure = error
            }
        }
        if let firstFailure { throw firstFailure }
    }

    private func requireOutsideWorker() throws {
        guard ScreenWorkerContext.serviceID != serviceID else {
            throw ScreenWorkerError.maintenanceInsideWorker
        }
    }

    private func requireAvailable(_ resources: Set<BackgroundTaskResource>, excluding allocation: UUID) throws {
        for (id, worker) in workers where id != allocation {
            for requested in resources {
                for occupied in worker.resources where Self.conflicts(requested, occupied) {
                    throw ScreenWorkerError.resourceBusy
                }
            }
        }
    }

    private static func normalized(_ resources: Set<BackgroundTaskResource>) -> Set<BackgroundTaskResource> {
        Set(resources.map { resource in
            switch resource {
            case .application(let id): return .application(id.lowercased())
            case .integration(let id): return .integration(id.lowercased())
            case .workspace(let path):
                return .workspace(URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path)
            }
        })
    }

    private static func conflicts(_ left: BackgroundTaskResource, _ right: BackgroundTaskResource) -> Bool {
        if case .workspace(let leftPath) = left, case .workspace(let rightPath) = right {
            let leftComponents = URL(fileURLWithPath: leftPath).pathComponents
            let rightComponents = URL(fileURLWithPath: rightPath).pathComponents
            return leftComponents.starts(with: rightComponents) || rightComponents.starts(with: leftComponents)
        }
        return left == right
    }
}
