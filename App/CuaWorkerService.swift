import Foundation
import PerryGuide
import PerryRuntimes

enum CuaWorkerScope: Hashable, Sendable {
    case background, foreground, guide, dictation, health

    var capacity: Int { self == .background ? 3 : 1 }
}

enum CuaWorkerError: Error, Equatable {
    case admissionClosed
    case capacityReached
    case resourceBusy
    case retired
    case operationDidNotStop
    case maintenanceInsideWorker
}

struct CuaWorkerHandle: Sendable {
    fileprivate let service: CuaWorkerService
    fileprivate let allocation: UUID

    func capture(target: CuaTargetHint?) async throws -> CuaCapturedWindow {
        try await service.capture(target: target, allocation: allocation)
    }

    func execute(_ action: ComputerAction) async throws -> StepResult {
        try await service.execute(action, allocation: allocation)
    }

    func insertText(_ text: String, target: CuaTargetHint) async throws -> CuaWindowTarget {
        try await service.insertText(text, target: target, allocation: allocation)
    }

    func claimResources(_ resources: Set<BackgroundTaskResource>) async throws {
        try await service.claim(resources, allocation: allocation)
    }

    func retire() async throws {
        try await service.retire(allocation)
    }
}

private enum CuaWorkerContext {
    @TaskLocal static var serviceID: UUID?
}

actor CuaWorkerService {
    private enum Admission { case accepting, maintenance, blocked, closed }

    private struct Worker {
        let scope: CuaWorkerScope
        let client: CuaDriverClient
        var resources: Set<BackgroundTaskResource>
        var cancelOperation: @Sendable () -> Void = {}
        var operationFinished = false
        var waiter: CheckedContinuation<Void, Never>?
        var retirement: Task<Void, Error>?
        var completion: Task<Void, Error>?
        var stopDeadline: ContinuousClock.Instant?
    }

    private let serviceID = UUID()
    private let configuration: CuaDriverConfiguration?
    private var admission = Admission.accepting
    private var workers: [UUID: Worker] = [:]
    private var maintenanceCompletion: Task<Void, Never>?

    init() { configuration = nil }

    init(configuration: CuaDriverConfiguration) {
        self.configuration = configuration
    }

    func withWorker<Value: Sendable>(
        scope: CuaWorkerScope,
        resources: Set<BackgroundTaskResource>,
        operation: @escaping @Sendable (CuaWorkerHandle) async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        guard admission == .accepting else { throw CuaWorkerError.admissionClosed }
        guard workers.values.filter({ $0.scope == scope }).count < scope.capacity else {
            throw CuaWorkerError.capacityReached
        }
        let allocation = UUID()
        let resources = Self.normalized(resources)
        try requireAvailable(resources, excluding: allocation)
        let client = configuration.map { CuaDriverClient(configuration: $0, allowsRestart: false) }
            ?? CuaDriverClient(allowsRestart: false)
        workers[allocation] = Worker(scope: scope, client: client, resources: resources)
        let handle = CuaWorkerHandle(service: self, allocation: allocation)
        let serviceID = serviceID
        let task = Task {
            let result: Result<Value, Error>
            do {
                let value = try await CuaWorkerContext.$serviceID.withValue(serviceID) {
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
        guard admission == .accepting || admission == .blocked else { throw CuaWorkerError.admissionClosed }
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
        guard admission == .maintenance else { throw CuaWorkerError.admissionClosed }
        let serviceID = serviceID
        let task = Task {
            try await CuaWorkerContext.$serviceID.withValue(serviceID) {
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

    func health() async -> CuaDriverHealth {
        do {
            return try await withWorker(scope: .health, resources: []) { handle in
                let client = try await self.client(for: handle.allocation)
                return await client.health()
            }
        } catch {
            return CuaDriverHealth(ready: false, summary: "Cua worker health check failed: \(error.localizedDescription)")
        }
    }

    fileprivate func claim(_ resources: Set<BackgroundTaskResource>, allocation: UUID) throws {
        try Task.checkCancellation()
        _ = try client(for: allocation)
        let resources = Self.normalized(resources)
        try requireAvailable(resources, excluding: allocation)
        workers[allocation]?.resources.formUnion(resources)
    }

    fileprivate func capture(target hint: CuaTargetHint?, allocation: UUID) async throws -> CuaCapturedWindow {
        do {
            let client = try client(for: allocation)
            let sessionID = allocation.uuidString
            let target = try await client.resolveTarget(hint, sessionID: sessionID)
            try claim([.application(target.bundleID)], allocation: allocation)
            return try await client.capture(resolvedTarget: target, sessionID: sessionID)
        } catch let error as CuaDriverError where error == .noTargetWindow {
            throw error
        } catch {
            beginRetirement(allocation)
            throw error
        }
    }

    fileprivate func insertText(_ text: String, target hint: CuaTargetHint, allocation: UUID) async throws -> CuaWindowTarget {
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
                throw CuaDriverError.targetNotFound
            }
            try claim([.application(target.bundleID)], allocation: allocation)
            return try await client.execute(action, sessionID: allocation.uuidString)
        } catch let error as CuaDriverError where error == .targetMismatch {
            // A refused identity leaves the worker healthy; the plan, not the
            // driver, was wrong. Surface the mismatch instead of retiring.
            throw error
        } catch {
            beginRetirement(allocation)
            throw error
        }
    }

    fileprivate func retire(_ allocation: UUID) async throws {
        guard workers[allocation] != nil else { throw CuaWorkerError.retired }
        try await beginRetirement(allocation).value
    }

    private func client(for allocation: UUID) throws -> CuaDriverClient {
        guard let worker = workers[allocation], worker.retirement == nil else {
            throw CuaWorkerError.retired
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
                throw CuaWorkerError.operationDidNotStop
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
            // Once retirement has run the entry must go either way: a thrown
            // terminationUnconfirmed still means SIGKILL was delivered, and
            // keeping the entry wedges its scope slot and claimed resources
            // until relaunch — the drill watched one retirement failure kill
            // every later capture.
            defer { self.workers[allocation] = nil }
            try await retirement.value
            try await self.waitForStoppedOperation(allocation)
        }
        workers[allocation]?.completion = completion
        return completion
    }

    private func stopWorkers() async throws {
        let completions = workers.keys.map { completeRetirement($0) }
        for completion in completions {
            try await completion.value
        }
    }

    private func requireOutsideWorker() throws {
        guard CuaWorkerContext.serviceID != serviceID else {
            throw CuaWorkerError.maintenanceInsideWorker
        }
    }

    private func requireAvailable(_ resources: Set<BackgroundTaskResource>, excluding allocation: UUID) throws {
        for (id, worker) in workers where id != allocation {
            for requested in resources {
                for occupied in worker.resources where Self.conflicts(requested, occupied) {
                    throw CuaWorkerError.resourceBusy
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
