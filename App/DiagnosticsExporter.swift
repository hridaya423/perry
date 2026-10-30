import AppKit
import PerryCore
import PerryGuide
import PerryRuntimes

/// Save-panel exports for support data: the activity log on its own, or the
/// redacted diagnostics bundle. Gathers, asks, writes, reports.
@MainActor
struct DiagnosticsExporter {
    let activityLog: ActivityLog
    let transcripts: TranscriptStore
    let memory: MemoryStore
    let setStatus: (String) -> Void

    func exportActivityLog() {
        Task { @MainActor in
            do {
                let data = try await activityLog.exportData()
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "perry-activity.json"
                panel.allowedContentTypes = [.json]
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try data.write(to: url, options: .atomic)
                setStatus("Activity log exported.")
            } catch {
                setStatus("Activity export failed: \(error.localizedDescription)")
            }
        }
    }

    func exportDiagnostics() {
        Task { @MainActor in
            do {
                let activity = await activityLog.snapshot()
                let transcripts = await transcripts.snapshot()
                let memoryConfiguration = await memory.currentConfiguration()
                let memoryRecords = await memory.snapshot()
                let data = try DiagnosticsReporter.makeData(
                    activity: activity,
                    transcripts: transcripts,
                    memoryConfiguration: memoryConfiguration,
                    memoryRecords: memoryRecords,
                    permissions: await PerryPermissionSnapshot.probe(),
                    codexBundled: (try? CodexRuntime.bundledLocator()) != nil,
                    claudeInstalled: (try? CLIRuntime.locateExecutable()) != nil,
                    codexLogURL: RuntimeCatalog.codexRuntimeHome?.appendingPathComponent("app-server-stderr.log")
                )
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "perry-diagnostics.json"
                panel.allowedContentTypes = [.json]
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try data.write(to: url, options: .atomic)
                setStatus("Redacted diagnostics exported.")
            } catch {
                setStatus("Diagnostics export failed: \(error.localizedDescription)")
            }
        }
    }
}

extension AppController {
    func showHistory() {
        homeController.openHome(selection: .history)
    }

    func exportActivityLog() {
        DiagnosticsExporter(
            activityLog: activityLog, transcripts: transcriptStore,
            memory: memoryStore, setStatus: { [weak self] in self?.sessionStatus = $0 }
        ).exportActivityLog()
    }

    func exportDiagnostics() {
        DiagnosticsExporter(
            activityLog: activityLog, transcripts: transcriptStore,
            memory: memoryStore, setStatus: { [weak self] in self?.sessionStatus = $0 }
        ).exportDiagnostics()
    }
}
