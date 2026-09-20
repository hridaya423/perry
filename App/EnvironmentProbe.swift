import AppKit
import Foundation
import PerryCapture
import PerryCore
import PerryGuide
import PerryRuntimes

/// Owns environment sensing for planning: permission and Cua health
/// snapshots, live screen-context capture through the worker, and target
/// window/app resolution. DEBUG loaders substitute the real probes at this
/// boundary so owners below it stay headless-testable.
@MainActor
final class EnvironmentProbe {
    private let workers: CuaWorkerService
    private let memoryStore: MemoryStore
    private let oauthCoordinator: OAuthCoordinator
    private let remoteIntegrationPermissions: RemoteIntegrationPermissionStore
    private let spatialSelection: () -> SpatialSelection?
    private let storageDirectory: () -> URL?

#if DEBUG
    typealias PermissionSnapshotLoader = @MainActor () async -> PerryPermissionSnapshot
    typealias CuaHealthLoader = @MainActor () async -> CuaDriverHealth
    typealias ScreenContextLoader = @MainActor (CuaWorkerHandle, CuaTargetHint?) async -> (context: ScreenContext, target: CuaWindowTarget?)
    private let debugPermissionSnapshotLoader: PermissionSnapshotLoader?
    private let debugCuaHealthLoader: CuaHealthLoader?
    private let debugScreenContextLoader: ScreenContextLoader?

    init(
        workers: CuaWorkerService,
        memoryStore: MemoryStore,
        oauthCoordinator: OAuthCoordinator,
        remoteIntegrationPermissions: RemoteIntegrationPermissionStore,
        spatialSelection: @escaping () -> SpatialSelection?,
        storageDirectory: @escaping () -> URL?,
        permissionSnapshotLoader: PermissionSnapshotLoader? = nil,
        cuaHealthLoader: CuaHealthLoader? = nil,
        screenContextLoader: ScreenContextLoader? = nil
    ) {
        self.workers = workers
        self.memoryStore = memoryStore
        self.oauthCoordinator = oauthCoordinator
        self.remoteIntegrationPermissions = remoteIntegrationPermissions
        self.spatialSelection = spatialSelection
        self.storageDirectory = storageDirectory
        self.debugPermissionSnapshotLoader = permissionSnapshotLoader
        self.debugCuaHealthLoader = cuaHealthLoader
        self.debugScreenContextLoader = screenContextLoader
    }
#else
    init(
        workers: CuaWorkerService,
        memoryStore: MemoryStore,
        oauthCoordinator: OAuthCoordinator,
        remoteIntegrationPermissions: RemoteIntegrationPermissionStore,
        spatialSelection: @escaping () -> SpatialSelection?,
        storageDirectory: @escaping () -> URL?
    ) {
        self.workers = workers
        self.memoryStore = memoryStore
        self.oauthCoordinator = oauthCoordinator
        self.remoteIntegrationPermissions = remoteIntegrationPermissions
        self.spatialSelection = spatialSelection
        self.storageDirectory = storageDirectory
    }
#endif

    func permissionSnapshot() async -> PerryPermissionSnapshot {
#if DEBUG
        if let debugPermissionSnapshotLoader {
            return await debugPermissionSnapshotLoader()
        }
#endif
        return await PerryPermissionSnapshot.probe()
    }

    func cuaHealth() async -> CuaDriverHealth {
#if DEBUG
        if let debugCuaHealthLoader {
            return await debugCuaHealthLoader()
        }
#endif
        return await workers.health()
    }

    static func captureIsUsable(_ context: ScreenContext) -> Bool {
        guard let reference = context.screenshotReferenceID else { return false }
        return reference.hasPrefix("cua:") && !reference.hasPrefix("cua:failed:")
    }

    func captureScreenContext(
        worker: CuaWorkerHandle,
        targetHint: CuaTargetHint? = nil
    ) async -> (context: ScreenContext, target: CuaWindowTarget?) {
#if DEBUG
        if let debugScreenContextLoader {
            return await debugScreenContextLoader(worker, targetHint)
        }
#endif
        let integrationContext = await remoteIntegrationPromptContext()
        let selectedWindow = spatialSelection()?.window
        let initialBundleID = targetHint == nil
            ? selectedWindow?.appBundleID ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            : nil
        let initialTitle = targetHint == nil
            ? selectedWindow?.title
            : targetHint?.windowTitle
        let resolvedHint = CuaTargetHint(
            bundleID: targetHint?.bundleID ?? initialBundleID,
            processID: targetHint?.processID ?? processID(for: initialBundleID),
            windowID: targetHint?.windowID,
            windowTitle: targetHint?.windowTitle ?? initialTitle
        )

        do {
            let capture = try await worker.capture(target: resolvedHint)
            let groundedAppBundleID = capture.target.bundleID
            let groundedTitle = capture.target.title.isEmpty ? initialTitle : capture.target.title
            let memoryContext = await memoryStore.promptContext(appBundleID: groundedAppBundleID)
            let visionTextContext = try? await Task.detached(priority: .userInitiated) {
                try PerryVisionTextRecognizer.recognizeText(in: capture.screenshotData)
            }.value.map { observation in
                let box = observation.normalizedBoundingBox
                return "\(observation.text) [normalized x \(String(format: "%.3f", box.midX)), y \(String(format: "%.3f", box.midY)), confidence \(Int((observation.confidence * 100).rounded()))%]"
            }.joined(separator: "\n")
            return (
                context: ScreenContext(
                frontAppBundleID: groundedAppBundleID,
                frontWindowTitle: groundedTitle,
                accessibilitySnapshot: capture.accessibilitySnapshot,
                screenshotReferenceID: "cua:\(capture.target.connectionGeneration):\(UUID().uuidString):\(capture.snapshotID ?? "window")",
                screenshotJPEGData: capture.screenshotData,
                screenshotMIMEType: capture.screenshotMIMEType,
                screenshotCoordinateSpace: .windowPixels,
                visionTextContext: visionTextContext,
                spatialRegionDescription: spatialSelection()?.description,
                appSkillContext: AppSkillLibrary(storageDirectory: storageDirectory()).promptContext(for: groundedAppBundleID),
                memoryContext: memoryContext,
                remoteIntegrationContext: integrationContext
                ),
                target: capture.target
            )
        } catch {
            let memoryContext = await memoryStore.promptContext(appBundleID: initialBundleID)
            return (
                ScreenContext(
                    frontAppBundleID: initialBundleID,
                    frontWindowTitle: initialTitle,
                    accessibilitySnapshot: nil,
                    screenshotReferenceID: "cua:failed:\(UUID().uuidString)",
                    screenshotCoordinateSpace: .windowPixels,
                    spatialRegionDescription: spatialSelection()?.description,
                    appSkillContext: AppSkillLibrary(storageDirectory: storageDirectory()).promptContext(for: initialBundleID),
                    memoryContext: memoryContext,
                    remoteIntegrationContext: integrationContext
                ),
                nil
            )
        }
    }

    private func remoteIntegrationPromptContext() async -> String {
        var connected: [RemoteIntegrationDefinition] = []
        for definition in RemoteIntegrationDefinition.catalog {
            do {
                guard try await oauthCoordinator.hasCredential(for: definition) else { continue }
                connected.append(definition)
            } catch {
                return "Remote integration credentials need attention in Settings: \(error.localizedDescription)"
            }
        }
        guard !connected.isEmpty else { return "No remote integrations are connected." }
        return connected.map { definition in
            let reads = definition.allowedReadPathPrefixes.joined(separator: ", ")
            let writes = definition.allowedWritePathPrefixes.isEmpty
                ? "none"
                : definition.allowedWritePathPrefixes.joined(separator: ", ")
            let writeState = definition.allowedWritePathPrefixes.isEmpty
                ? "unavailable"
                : remoteIntegrationPermissions.writesEnabled(for: definition) ? "enabled after approval" : "disabled"
            return "- \(definition.id) (\(definition.displayName)): read \(reads); write \(writes) (\(writeState))"
        }.joined(separator: "\n")
    }

    func processID(for bundleID: String?) -> Int32? {
        if let bundleID,
           let application = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.isActive })
            ?? NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return application.processIdentifier
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    func processID(for metadata: BackgroundTaskMetadata?) -> Int32? {
        if let processID = metadata?.targetProcessID,
           let application = NSRunningApplication(processIdentifier: processID),
           let expectedBundleID = metadata?.targetAppBundleID,
           application.bundleIdentifier?.caseInsensitiveCompare(expectedBundleID) == .orderedSame {
            return processID
        }
        return processID(for: metadata?.targetAppBundleID)
    }

    func currentTargetHint() -> CuaTargetHint {
        let selectedWindow = spatialSelection()?.window
        let bundleID = selectedWindow?.appBundleID ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return CuaTargetHint(
            bundleID: bundleID,
            processID: processID(for: bundleID),
            windowTitle: selectedWindow?.title
        )
    }

    func targetWindow(for context: ScreenContext) -> WindowContext? {
        if let bundleID = context.frontAppBundleID {
            return WindowContext(
                appBundleID: bundleID,
                title: context.frontWindowTitle ?? "Frontmost window"
            )
        }
        return spatialSelection()?.window
    }
}
