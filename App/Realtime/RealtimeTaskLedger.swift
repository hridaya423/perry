import AVFoundation
import Foundation
import PerryCore

enum RealtimeWorkerRole: String, CaseIterable, Sendable {
    case connection
    case receiver
    case commit
    case audioIngress = "audio_ingress"
    case shutdown
    case pipeline
    case cancellationCleanup = "cancellation_cleanup"
    case routeRecovery = "route_recovery"
}

struct RealtimeWorkerToken: Hashable, Sendable {
    let id: UUID
    let role: RealtimeWorkerRole
    let sessionGeneration: Int
    let utteranceGeneration: Int
}

struct RealtimeTaskLedger {
    private var activeWorkers: [UUID: RealtimeWorkerRole] = [:]
    private var startedByRole: [RealtimeWorkerRole: Int] = [:]
    private var finishedByRole: [RealtimeWorkerRole: Int] = [:]
    private var sequence = 0

    mutating func start(
        _ role: RealtimeWorkerRole,
        sessionGeneration: Int,
        utteranceGeneration: Int
    ) -> (RealtimeWorkerToken, RealtimeTaskSnapshot) {
        let token = RealtimeWorkerToken(
            id: UUID(),
            role: role,
            sessionGeneration: sessionGeneration,
            utteranceGeneration: utteranceGeneration
        )
        activeWorkers[token.id] = role
        startedByRole[role, default: 0] += 1
        return (token, snapshot(sessionGeneration: sessionGeneration, utteranceGeneration: utteranceGeneration))
    }

    mutating func finish(_ token: RealtimeWorkerToken) -> RealtimeTaskSnapshot? {
        guard activeWorkers.removeValue(forKey: token.id) == token.role else { return nil }
        finishedByRole[token.role, default: 0] += 1
        return snapshot(
            sessionGeneration: token.sessionGeneration,
            utteranceGeneration: token.utteranceGeneration
        )
    }

    private mutating func snapshot(
        sessionGeneration: Int,
        utteranceGeneration: Int
    ) -> RealtimeTaskSnapshot {
        sequence += 1
        let activeByRole = Dictionary(grouping: activeWorkers.values, by: { $0 })
            .mapValues(\.count)
            .stringKeys
        return RealtimeTaskSnapshot(
            sequence: sequence,
            sessionGeneration: sessionGeneration,
            utteranceGeneration: utteranceGeneration,
            active: activeWorkers.count,
            started: startedByRole.values.reduce(0, +),
            finished: finishedByRole.values.reduce(0, +),
            activeByRole: activeByRole,
            startedByRole: startedByRole.stringKeys,
            finishedByRole: finishedByRole.stringKeys
        )
    }
}

private extension Dictionary where Key == RealtimeWorkerRole, Value == Int {
    var stringKeys: [String: Int] {
        reduce(into: [:]) { result, entry in
            result[entry.key.rawValue] = entry.value
        }
    }
}
