import Foundation
import OSLog

enum PerfMark {
    private static let signposter = OSSignposter(subsystem: "app.perry", category: "latency")
    private static var log: PerformanceSampleLog? { try? PerformanceSampleLog.shared.get() }

    static func mark(_ name: StaticString) {
        signposter.emitEvent(name)
        write(name.description)
    }

    static func markDynamic(_ name: String) {
        write(name)
    }

    private static func write(_ name: String) {
        guard let log else { return }
        let marker = PerformanceMarker(name: name, capturedAt: Date())
        Task { try? await log.append(marker) }
    }
}

struct PerformanceSample: Codable, Equatable, Sendable {
    let metricID: String
    let collector: String
    let unit: String
    let value: Double
    let scenario: String

    enum CodingKeys: String, CodingKey {
        case metricID = "metric_id"
        case collector
        case unit
        case value
        case scenario
    }
}

struct PerformanceMarker: Equatable, Sendable {
    let name: String
    let capturedAt: Date
}

struct RealtimeTaskSnapshot: Codable, Equatable, Sendable {
    let sequence: Int
    let sessionGeneration: Int
    let utteranceGeneration: Int
    let active: Int
    let started: Int
    let finished: Int
    let activeByRole: [String: Int]
    let startedByRole: [String: Int]
    let finishedByRole: [String: Int]

    enum CodingKeys: String, CodingKey {
        case sequence
        case sessionGeneration = "session_generation"
        case utteranceGeneration = "utterance_generation"
        case active
        case started
        case finished
        case activeByRole = "active_by_role"
        case startedByRole = "started_by_role"
        case finishedByRole = "finished_by_role"
    }
}

actor PerformanceSampleLog {
    private struct Entry: Codable {
        let metricID: String
        let collector: String
        let unit: String
        let value: Double
        let scenario: String
        let capturedAt: String

        enum CodingKeys: String, CodingKey {
            case metricID = "metric_id"
            case collector
            case unit
            case value
            case scenario
            case capturedAt = "captured_at"
        }
    }

    private struct MarkerEntry: Codable {
        let name: String
        let capturedAt: String

        enum CodingKeys: String, CodingKey {
            case name
            case capturedAt = "captured_at"
        }
    }

    private struct TaskEntry: Codable {
        let sequence: Int
        let sessionGeneration: Int
        let utteranceGeneration: Int
        let active: Int
        let started: Int
        let finished: Int
        let activeByRole: [String: Int]
        let startedByRole: [String: Int]
        let finishedByRole: [String: Int]
        let capturedAt: String

        enum CodingKeys: String, CodingKey {
            case sequence
            case sessionGeneration = "session_generation"
            case utteranceGeneration = "utterance_generation"
            case active
            case started
            case finished
            case activeByRole = "active_by_role"
            case startedByRole = "started_by_role"
            case finishedByRole = "finished_by_role"
            case capturedAt = "captured_at"
        }

        init(snapshot: RealtimeTaskSnapshot, capturedAt: String) {
            sequence = snapshot.sequence
            sessionGeneration = snapshot.sessionGeneration
            utteranceGeneration = snapshot.utteranceGeneration
            active = snapshot.active
            started = snapshot.started
            finished = snapshot.finished
            activeByRole = snapshot.activeByRole
            startedByRole = snapshot.startedByRole
            finishedByRole = snapshot.finishedByRole
            self.capturedAt = capturedAt
        }
    }

    private let fileURL: URL
    private let markerFileURL: URL
    private let taskFileURL: URL
    private let encoder: JSONEncoder
    private let timestamp: @Sendable () -> Date

    init(fileURL: URL, timestamp: @escaping @Sendable () -> Date = { Date() }) throws {
        guard fileURL.path.hasPrefix("/") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        self.fileURL = fileURL.standardizedFileURL
        markerFileURL = fileURL.standardizedFileURL.appendingPathExtension("markers.jsonl")
        taskFileURL = fileURL.standardizedFileURL.appendingPathExtension("tasks.jsonl")
        self.timestamp = timestamp
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
    }

    static let shared = Result { try configured() }

    static func configured(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> PerformanceSampleLog? {
        guard let path = environment["PERRY_PERFORMANCE_EVENT_LOG"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return nil }
        return try PerformanceSampleLog(fileURL: URL(fileURLWithPath: path))
    }

    func append(_ sample: PerformanceSample) throws {
        let entry = Entry(
            metricID: sample.metricID,
            collector: sample.collector,
            unit: sample.unit,
            value: sample.value,
            scenario: sample.scenario,
            capturedAt: ISO8601DateFormatter().string(from: timestamp())
        )
        try append(encoder.encode(entry), to: fileURL)
    }

    func append(_ marker: PerformanceMarker) throws {
        let markerTimestamp = ISO8601DateFormatter()
        markerTimestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let entry = MarkerEntry(
            name: marker.name,
            capturedAt: markerTimestamp.string(from: marker.capturedAt)
        )
        try append(encoder.encode(entry), to: markerFileURL)
    }

    func append(_ snapshot: RealtimeTaskSnapshot) throws {
        let taskTimestamp = ISO8601DateFormatter()
        taskTimestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let entry = TaskEntry(snapshot: snapshot, capturedAt: taskTimestamp.string(from: timestamp()))
        try append(encoder.encode(entry), to: taskFileURL)
    }

    private func append(_ encodedEntry: Data, to destination: URL) throws {
        var data = encodedEntry
        data.append(0x0A)
        if !FileManager.default.fileExists(atPath: destination.path) {
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: destination)
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try handle.close()
            throw error
        }
    }
}
