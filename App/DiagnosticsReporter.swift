import Foundation
import PerryCapture
import PerryCore
import PerryGuide

struct DiagnosticsReporter {
    static func makeData(
        activity: [ActivityEntry],
        transcripts: [TranscriptEntry],
        memoryConfiguration: MemoryConfiguration,
        memoryRecords: [MemoryRecord],
        permissions: PerryPermissionSnapshot,
        codexBundled: Bool,
        claudeInstalled: Bool
    ) throws -> Data {
        let report = Report(
            generatedAt: Date(),
            app: AppInfo(
                version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                architecture: architecture
            ),
            permissions: PermissionInfo(
                accessibility: permissions.accessibility,
                screenRecording: permissions.screenRecording.rawValue,
                microphone: permissions.microphone.rawValue,
                inputMonitoring: permissions.inputMonitoring
            ),
            runtimes: RuntimeInfo(
                bundledCodex: codexBundled,
                installedClaudeCode: claudeInstalled,
                privateLocalPlanner: true
            ),
            activity: ActivityInfo(
                total: activity.count,
                outcomes: counts(activity.map { $0.outcome.rawValue }),
                tiers: counts(activity.map { $0.tier.rawValue }),
                verified: activity.compactMap(\.verified).filter { $0 }.count,
                needsChecking: activity.compactMap(\.verified).filter { !$0 }.count
            ),
            transcripts: TranscriptInfo(
                total: transcripts.count,
                outcomes: counts(transcripts.map { $0.outcome.rawValue }),
                verified: transcripts.compactMap(\.verified).filter { $0 }.count,
                needsChecking: transcripts.compactMap(\.verified).filter { !$0 }.count
            ),
            memory: MemoryInfo(
                enabled: memoryConfiguration.enabled,
                enabledCategories: MemoryRecord.Category.allCases.filter { memoryConfiguration.categoryToggles[$0] == true }.map(\.rawValue),
                recordCounts: Dictionary(grouping: memoryRecords, by: { $0.category.rawValue }).mapValues(\.count)
            )
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report)
    }

    private static func counts(_ values: [String]) -> [String: Int] {
        Dictionary(grouping: values, by: { $0 }).mapValues(\.count)
    }

    private static var architecture: String {
#if arch(arm64)
        return "arm64"
#elseif arch(x86_64)
        return "x86_64"
#else
        return "unknown"
#endif
    }

    private struct Report: Codable {
        let generatedAt: Date
        let app: AppInfo
        let permissions: PermissionInfo
        let runtimes: RuntimeInfo
        let activity: ActivityInfo
        let transcripts: TranscriptInfo
        let memory: MemoryInfo
    }

    private struct AppInfo: Codable {
        let version: String
        let build: String
        let operatingSystem: String
        let architecture: String
    }

    private struct PermissionInfo: Codable {
        let accessibility: Bool
        let screenRecording: String
        let microphone: String
        let inputMonitoring: Bool
    }

    private struct RuntimeInfo: Codable {
        let bundledCodex: Bool
        let installedClaudeCode: Bool
        let privateLocalPlanner: Bool
    }

    private struct ActivityInfo: Codable {
        let total: Int
        let outcomes: [String: Int]
        let tiers: [String: Int]
        let verified: Int
        let needsChecking: Int
    }

    private struct TranscriptInfo: Codable {
        let total: Int
        let outcomes: [String: Int]
        let verified: Int
        let needsChecking: Int
    }

    private struct MemoryInfo: Codable {
        let enabled: Bool
        let enabledCategories: [String]
        let recordCounts: [String: Int]
    }
}
