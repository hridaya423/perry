import AppKit
import PerryBrain
import PerryGuide
import PerryOverlay

@MainActor
enum AppToolHost {
    static func make(
        overlayState: PerryCursorState,
        workers: CuaWorkerService,
        lease: ForegroundWorkerLease,
        supportDirectory: URL?,
        integrationBackend: AppIntegrationBackend,
        perryStore: PerryStore?,
        locate: LocateTarget? = nil,
        openSettings: @escaping @MainActor (SettingsPage) -> Void
    ) -> PerryToolHost {
        let observations = AgentObservationStore.shared
        let ghost = AgentGhostCursor(overlayState: overlayState)
        return PerryToolHost(executors:
            DrawTools(overlayState: overlayState, observations: observations).executors
            + ScreenTools(workers: workers, lease: lease, observations: observations, skills: AppSkillLibrary(storageDirectory: supportDirectory)).executors
            + UITools(
                workers: workers,
                lease: lease,
                observations: observations,
                onActuation: { point, label in
                    Task { @MainActor in ghost.track(axPoint: point, label: label) }
                },
                locate: locate
            ).executors
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

    private static func packageExecutors(
        supportDirectory: URL?,
        integrationBackend: AppIntegrationBackend,
        perryStore: PerryStore?,
        openSettings: @escaping @MainActor (SettingsPage) -> Void
    ) -> [any ToolExecutor] {
        guard let support = supportDirectory else { return [] }
        var executors: [any ToolExecutor] = []
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

@MainActor
private struct AgentGhostCursor {
    private static let id = UUID(uuidString: "A6E11C7E-0000-4A00-9E00-000000000007")!
    let overlayState: PerryCursorState

    func track(axPoint: CGPoint, label: String?) {
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let screenPoint = CGPoint(x: axPoint.x, y: primaryMaxY - axPoint.y)
        var cursor = overlayState.externalSecondaryCursors.first { $0.id == Self.id }
            ?? PerryExternalCursor(id: Self.id, screenLocation: screenPoint, caption: nil, accentHex: "#9CCBB6")
        cursor.screenLocation = screenPoint
        cursor.caption = label
        overlayState.externalSecondaryCursors.removeAll { $0.id == Self.id }
        overlayState.externalSecondaryCursors.append(cursor)
    }
}
