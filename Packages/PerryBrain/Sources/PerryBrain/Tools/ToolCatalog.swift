import Foundation

/// One-call assembly of every package-provided agent executor, for the app
/// composition root. App-side executors (screen/draw/ui/browser over the Cua
/// driver and overlay) are appended by the app itself.
public enum ToolCatalog {
    public static func agentExecutors(
        files: any WorkspaceFileBackend,
        memory: MemoryFiles,
        integrations: any IntegrationBackend,
        perrys: PerryStore,
        openSettings: (@Sendable (String?) async -> Void)? = nil
    ) -> [any ToolExecutor] {
        FileToolExecutors.make(backend: files)
            + MemoryToolExecutors.make(files: memory)
            + IntegrationToolExecutors.make(backend: integrations)
            + PerryToolExecutors.make(store: perrys, openSettings: openSettings)
    }
}
