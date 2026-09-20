import Foundation
import XCTest
@testable import Perry

final class PerformanceSampleLogTests: XCTestCase {
    func testConfiguredLogRequiresAnExplicitPath() throws {
        XCTAssertNil(try PerformanceSampleLog.configured(environment: [:]))

        let log = try PerformanceSampleLog.configured(environment: [
            "PERRY_PERFORMANCE_EVENT_LOG": "/tmp/perry-performance.jsonl",
        ])

        XCTAssertNotNil(log)
    }

    func testAppendWritesIndependentJSONLines() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-performance-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try FileManager.default.removeItem(at: directory)
        }
        let fileURL = directory.appendingPathComponent("events.jsonl")
        let date = Date(timeIntervalSince1970: 1_788_000_000)
        let log = try PerformanceSampleLog(fileURL: fileURL, timestamp: { date })

        try await log.append(PerformanceSample(
            metricID: "voice.realtime_first_audio",
            collector: "perry.app.realtime-first-audio.v1",
            unit: "ms",
            value: 240,
            scenario: "fixture"
        ))
        try await log.append(PerformanceSample(
            metricID: "voice.realtime_first_audio",
            collector: "perry.app.realtime-first-audio.v1",
            unit: "ms",
            value: 260,
            scenario: "fixture"
        ))

        let lines = try String(contentsOf: fileURL, encoding: .utf8)
            .split(separator: "\n")
            .map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.map { $0["metric_id"] as? String }, ["voice.realtime_first_audio", "voice.realtime_first_audio"])
        XCTAssertEqual(Set(lines.compactMap { $0["collector"] as? String }), Set(["perry.app.realtime-first-audio.v1"]))
        XCTAssertEqual(lines.map { $0["value"] as? Double }, [240, 260])
        XCTAssertEqual(lines.map { $0["captured_at"] as? String }, ["2026-08-29T10:40:00Z", "2026-08-29T10:40:00Z"])
    }

    func testMarkerUsesASeparateTimestampedSidecar() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-performance-marker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try FileManager.default.removeItem(at: directory)
        }
        let fileURL = directory.appendingPathComponent("events.jsonl")
        let log = try PerformanceSampleLog(fileURL: fileURL)

        try await log.append(PerformanceMarker(
            name: "voice.barge_in_requested",
            capturedAt: Date(timeIntervalSince1970: 1_788_000_000.123)
        ))

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let markerURL = fileURL.appendingPathExtension("markers.jsonl")
        let marker = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: markerURL)) as? [String: String]
        )
        XCTAssertEqual(marker, [
            "captured_at": "2026-08-29T10:40:00.123Z",
            "name": "voice.barge_in_requested",
        ])
    }

    func testTaskSnapshotUsesAContentFreeSidecar() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-performance-tasks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try FileManager.default.removeItem(at: directory)
        }
        let fileURL = directory.appendingPathComponent("events.jsonl")
        let date = Date(timeIntervalSince1970: 1_788_000_000.123)
        let log = try PerformanceSampleLog(fileURL: fileURL, timestamp: { date })

        try await log.append(RealtimeTaskSnapshot(
            sequence: 3,
            sessionGeneration: 2,
            utteranceGeneration: 7,
            active: 1,
            started: 2,
            finished: 1,
            activeByRole: ["commit": 1],
            startedByRole: ["commit": 2],
            finishedByRole: ["commit": 1]
        ))

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.appendingPathExtension("markers.jsonl").path))
        let taskURL = fileURL.appendingPathExtension("tasks.jsonl")
        let entry = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: taskURL)) as? [String: Any]
        )
        XCTAssertEqual(entry["captured_at"] as? String, "2026-08-29T10:40:00.123Z")
        XCTAssertEqual(entry["sequence"] as? Int, 3)
        XCTAssertEqual(entry["session_generation"] as? Int, 2)
        XCTAssertEqual(entry["utterance_generation"] as? Int, 7)
        XCTAssertEqual(entry["active"] as? Int, 1)
        XCTAssertEqual(entry["started"] as? Int, 2)
        XCTAssertEqual(entry["finished"] as? Int, 1)
        XCTAssertEqual(entry["active_by_role"] as? [String: Int], ["commit": 1])
        XCTAssertEqual(entry["started_by_role"] as? [String: Int], ["commit": 2])
        XCTAssertEqual(entry["finished_by_role"] as? [String: Int], ["commit": 1])
    }
}
