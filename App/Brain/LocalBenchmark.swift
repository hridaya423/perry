import Foundation

enum LocalBenchmark {
    struct Conditions: Equatable {
        var onBattery: Bool
        var lowPowerMode: Bool
        var thermalState: ProcessInfo.ThermalState
    }

    enum Postponement: Equatable {
        case onBattery
        case lowPowerMode
        case tooHot
    }

    struct Rung: Codable, Equatable, Sendable {
        let model: String
        let activeGB: Double
    }

    struct Limits: Equatable, Sendable {
        let referenceTurnSeconds: Double
        let decodeTokensPerSecond: Double

        static let interactive = Limits(referenceTurnSeconds: 6, decodeTokensPerSecond: 15)
        static let deep = Limits(referenceTurnSeconds: 20, decodeTokensPerSecond: 8)
    }

    struct Measurement: Codable, Equatable, Sendable {
        var loadSeconds: Double
        var coldTurnSeconds: Double
        var referenceTurnSeconds: Double
        var decodeTokensPerSecond: Double
        var peakMemoryGB: Double
        var toolCallsPassed: Int
        var newPageOuts: Int

        var prefixCacheWorks: Bool { referenceTurnSeconds <= coldTurnSeconds * 0.7 }
    }

    struct Attempt: Codable, Equatable, Sendable {
        let rung: Rung
        let measurement: Measurement
        let accepted: Bool
    }

    struct Outcome: Codable, Equatable, Sendable {
        let chosen: Rung?
        let attempts: [Attempt]
    }

    struct Record: Codable, Equatable, Sendable {
        let fingerprint: [String: String]
        let engineVersion: String
        let modelHash: String
        let interactive: Outcome
        var deep: Outcome?
        var useMTP: Bool?
    }

    static let toolCallCount = 5
    static let maxStepDowns = 3
    static let fitShare = 0.75

    static func postponement(_ conditions: Conditions) -> Postponement? {
        if conditions.onBattery { return .onBattery }
        if conditions.lowPowerMode { return .lowPowerMode }
        if conditions.thermalState.rawValue > ProcessInfo.ThermalState.fair.rawValue { return .tooHot }
        return nil
    }

    static func startIndex(rungs: [Rung], preferred: Int, workingSetGB: Double) -> Int? {
        rungs.indices.dropFirst(preferred).first { rungs[$0].activeGB <= workingSetGB * fitShare }
    }

    static func accepts(_ measurement: Measurement, limits: Limits, workingSetGB: Double) -> Bool {
        measurement.referenceTurnSeconds <= limits.referenceTurnSeconds
            && measurement.decodeTokensPerSecond >= limits.decodeTokensPerSecond
            && measurement.peakMemoryGB <= workingSetGB * fitShare
            && measurement.newPageOuts == 0
            && measurement.toolCallsPassed == toolCallCount
    }

    static func run(
        rungs: [Rung],
        preferred: Int,
        limits: Limits,
        workingSetGB: Double,
        measure: (Rung) async throws -> Measurement
    ) async rethrows -> Outcome {
        guard let start = startIndex(rungs: rungs, preferred: preferred, workingSetGB: workingSetGB) else {
            return Outcome(chosen: nil, attempts: [])
        }
        var attempts: [Attempt] = []
        for rung in rungs[start...].prefix(maxStepDowns + 1) {
            let measurement = try await measure(rung)
            let accepted = accepts(measurement, limits: limits, workingSetGB: workingSetGB)
            attempts.append(Attempt(rung: rung, measurement: measurement, accepted: accepted))
            if accepted { return Outcome(chosen: rung, attempts: attempts) }
        }
        return Outcome(chosen: nil, attempts: attempts)
    }

    static func keepsMTP(answerSeconds plain: Double, withMTP: Double) -> Bool {
        withMTP <= plain * 0.85
    }

    static func summary(_ outcome: Outcome) -> String? {
        guard let accepted = outcome.attempts.last(where: \.accepted) else { return nil }
        let seconds = max(1, Int(accepted.measurement.referenceTurnSeconds.rounded()))
        return "Perry answers screen questions in about \(seconds) second\(seconds == 1 ? "" : "s") on this Mac."
    }

    static func save(_ record: Record, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: url, options: .atomic)
    }

    static func load(from url: URL) -> Record? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    static func needsRerun(_ record: Record?, fingerprint: [String: String], engineVersion: String, modelHash: String) -> Bool {
        guard let record else { return true }
        return record.fingerprint["osBuild"] != fingerprint["osBuild"]
            || record.engineVersion != engineVersion
            || record.modelHash != modelHash
    }
}
