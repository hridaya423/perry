import AppKit
import PerryBrain
import PerryOverlay

/// Model→world dispatch. Executors bind the app's real services (Cua workers,
/// overlay ink, memory, Perrys); package-level executor cores
/// (file/memory/integration/perry) plug in alongside these. The active
/// foreground Do run lends its worker to tool executors so agent calls share
/// the session's app lock instead of colliding with it.
@MainActor
enum AppToolHost {
    static func make(
        overlayState: PerryCursorState,
        workers: CuaWorkerService,
        lease: ForegroundWorkerLease,
        supportDirectory: URL?,
        integrationBackend: AppIntegrationBackend,
        perryStore: PerryStore?,
        openSettings: @escaping @MainActor (SettingsPage) -> Void
    ) -> PerryToolHost {
        let observations = AgentObservationStore.shared
        let ghost = AgentGhostCursor(overlayState: overlayState)
        return PerryToolHost(executors:
            DrawTools(overlayState: overlayState, observations: observations).executors
            + ScreenTools(workers: workers, lease: lease, observations: observations).executors
            + UITools(
                workers: workers,
                lease: lease,
                observations: observations,
                onActuation: { point, label in
                    Task { @MainActor in ghost.track(axPoint: point, label: label) }
                }
            ).executors
            + BrowserTools(workers: workers, lease: lease, observations: observations).executors
            + DocumentTools(workers: workers, lease: lease, observations: observations).executors
            + AppTools().executors
            + packageExecutors(
                supportDirectory: supportDirectory,
                integrationBackend: integrationBackend,
                perryStore: perryStore,
                openSettings: openSettings
            )
        )
    }

    /// Package-level executor cores (Phase 7c): workspace files, memory files,
    /// integrations, and Perrys. `files:`/support-dir pieces are skipped when
    /// the support directory is unavailable rather than silently rooted
    /// somewhere else.
    private static func packageExecutors(
        supportDirectory: URL?,
        integrationBackend: AppIntegrationBackend,
        perryStore: PerryStore?,
        openSettings: @escaping @MainActor (SettingsPage) -> Void
    ) -> [any ToolExecutor] {
        guard let support = supportDirectory else { return [] }
        var executors: [any ToolExecutor] = []
        // LocalWorkspaceFiles requires an existing root — the workspace is
        // created on first launch, empty until an agent writes to it.
        let workspace = support.appendingPathComponent("workspace", isDirectory: true)
        if let files = try? LocalWorkspaceFiles(root: workspace) {
            executors += FileToolExecutors.make(backend: files)
        }
        executors += MemoryToolExecutors.make(
            files: MemoryFiles(directory: support.appendingPathComponent("memory", isDirectory: true)),
            pronunciations: PronunciationStore(directory: support)
        )
        executors += IntegrationToolExecutors.make(backend: integrationBackend)
        if let perryStore {
            executors += PerryToolExecutors.make(
                store: perryStore,
                openSettings: { page in
                    Task { @MainActor in openSettings(SettingsPage(perryPage: page)) }
                }
            )
        }
        return executors
    }
}

/// Ghost cursor for agent work: a Perry cursor tracks each ui.* actuation
/// point so the user can watch without their real pointer ever moving.
@MainActor
private struct AgentGhostCursor {
    private static let id = UUID(uuidString: "A6E11C7E-0000-4A00-9E00-000000000007")!
    let overlayState: PerryCursorState

    func track(axPoint: CGPoint, label: String?) {
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let screenPoint = CGPoint(x: axPoint.x, y: primaryMaxY - axPoint.y)
        var cursor = overlayState.externalSecondaryCursors.first { $0.id == Self.id }
            ?? PerryExternalCursor(id: Self.id, screenLocation: screenPoint, caption: nil, accentHex: "#34D399")
        cursor.screenLocation = screenPoint
        cursor.caption = label
        overlayState.externalSecondaryCursors.removeAll { $0.id == Self.id }
        overlayState.externalSecondaryCursors.append(cursor)
    }
}
