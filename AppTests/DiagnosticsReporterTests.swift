import XCTest
import PerryCapture
import PerryCore
import PerryGuide
@testable import Perry

final class DiagnosticsReporterTests: XCTestCase {
    func testSeededSensitiveValuesNeverEnterDiagnosticsExport() throws {
        let secrets = [
            "prompt: rename the confidential acquisition file",
            "token-sk-live-4f62d9d1",
            "/Users/alice/Clients/Acme/forecast.xlsx",
            "transcript: revenue will miss by twelve percent",
            "document: Project Cedar closes Friday",
        ]
        let activity = ActivityEntry(
            actionSummary: secrets[0],
            targetAppBundleID: secrets[2],
            tier: .orange,
            outcome: .confirmed,
            reversible: true,
            verified: true
        )
        let transcript = TranscriptEntry(
            request: secrets[0],
            appBundleID: secrets[2],
            summary: secrets[3],
            outcome: .completed,
            startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 2),
            steps: [secrets[4]],
            verified: true
        )
        let memory = MemoryRecord(
            category: .pastSession,
            appBundleID: secrets[2],
            summary: secrets[4]
        )

        let data = try DiagnosticsReporter.makeData(
            activity: [activity],
            transcripts: [transcript],
            memoryConfiguration: MemoryConfiguration(),
            memoryRecords: [memory],
            permissions: PerryPermissionSnapshot(
                accessibility: true,
                screenRecording: .granted,
                microphone: .granted
            ),
            codexBundled: true,
            claudeInstalled: true
        )
        let export = String(decoding: data, as: UTF8.self)

        for secret in secrets {
            XCTAssertFalse(export.contains(secret))
        }
        XCTAssertTrue(export.contains(#""total" : 1"#))
        XCTAssertTrue(export.contains(#""confirmed" : 1"#))
        XCTAssertTrue(export.contains(#""completed" : 1"#))
        XCTAssertTrue(export.contains(#""pastSession" : 1"#))
    }

    func testCodexLogTailIsIncludedRedactedAndBounded() throws {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-log-\(UUID().uuidString).log")
        let home = NSHomeDirectory()
        let lines = (0..<200).map { "2026-10-11T12:00:\($0) INFO turn \(home)/secret/thing done\n" }.joined()
            + "WARN auth Bearer sk-deadbeef123 token=abc123def\n"
        try lines.write(to: logURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: logURL) }

        let data = try DiagnosticsReporter.makeData(
            activity: [],
            transcripts: [],
            memoryConfiguration: MemoryConfiguration(),
            memoryRecords: [],
            permissions: PerryPermissionSnapshot(
                accessibility: false,
                screenRecording: .denied,
                microphone: .denied
            ),
            codexBundled: true,
            claudeInstalled: false,
            codexLogURL: logURL
        )
        let export = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(export.contains("codexLogTail"))
        XCTAssertTrue(export.contains("WARN auth"))
        XCTAssertFalse(export.contains("sk-deadbeef123"))
        XCTAssertFalse(export.contains("abc123def"))
        XCTAssertFalse(export.contains(home))
    }
}
