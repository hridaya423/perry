import AppKit
import Foundation
import PerryCore
import PerryGuide
import PerryRuntimes

@MainActor
final class EnvironmentProbe {
    private let workers: ScreenWorkerService
    private let memoryStore: MemoryStore
    private let oauthCoordinator: OAuthCoordinator
    private let remoteIntegrationPermissions: RemoteIntegrationPermissionStore
    private let spatialSelection: () -> SpatialSelection?
    private let storageDirectory: () -> URL?
    private var invocationTarget: ScreenTargetHint?

    typealias PermissionSnapshotLoader = @MainActor () async -> PerryPermissionSnapshot
    typealias ScreenHealthLoader = @MainActor () async -> ScreenDriverHealth
    typealias ScreenContextLoader = @MainActor (ScreenWorkerHandle, ScreenTargetHint?) async -> (context: ScreenContext, target: ScreenWindowTarget?)
    private let permissionSnapshotLoader: PermissionSnapshotLoader?
    private let screenHealthLoader: ScreenHealthLoader?
    private let screenContextLoader: ScreenContextLoader?

    init(
        workers: ScreenWorkerService,
        memoryStore: MemoryStore,
        oauthCoordinator: OAuthCoordinator,
        remoteIntegrationPermissions: RemoteIntegrationPermissionStore,
        spatialSelection: @escaping () -> SpatialSelection?,
        storageDirectory: @escaping () -> URL?,
        permissionSnapshotLoader: PermissionSnapshotLoader? = nil,
        screenHealthLoader: ScreenHealthLoader? = nil,
        screenContextLoader: ScreenContextLoader? = nil
    ) {
        self.workers = workers
        self.memoryStore = memoryStore
        self.oauthCoordinator = oauthCoordinator
        self.remoteIntegrationPermissions = remoteIntegrationPermissions
        self.spatialSelection = spatialSelection
        self.storageDirectory = storageDirectory
        self.permissionSnapshotLoader = permissionSnapshotLoader
        self.screenHealthLoader = screenHealthLoader
        self.screenContextLoader = screenContextLoader
    }

    func permissionSnapshot() async -> PerryPermissionSnapshot {
        if let permissionSnapshotLoader {
            return await permissionSnapshotLoader()
        }
        return await PerryPermissionSnapshot.probe()
    }

    func screenHealth() async -> ScreenDriverHealth {
        if let screenHealthLoader {
            return await screenHealthLoader()
        }
        return await workers.health()
    }

    static func captureIsUsable(_ context: ScreenContext) -> Bool {
        guard let reference = context.screenshotReferenceID else { return false }
        return reference.hasPrefix("screen:") && !reference.hasPrefix("screen:failed:")
    }

    func captureScreenContext(
        worker: ScreenWorkerHandle,
        targetHint: ScreenTargetHint? = nil
    ) async -> (context: ScreenContext, target: ScreenWindowTarget?) {
        let resolvedHint = targetHint ?? currentTargetHint()
        if let screenContextLoader {
            return await screenContextLoader(worker, resolvedHint)
        }
        let initialBundleID = resolvedHint.bundleID
        let initialTitle = resolvedHint.windowTitle
        let integrationContext = await remoteIntegrationPromptContext()

        do {
            let capture = try await worker.capture(target: resolvedHint)
            let groundedAppBundleID = capture.target.bundleID
            let groundedTitle = capture.target.title.isEmpty ? initialTitle : capture.target.title
            let memoryContext = await memoryStore.promptContext(appBundleID: groundedAppBundleID)
            return (
                context: ScreenContext(
                frontAppBundleID: groundedAppBundleID,
                frontWindowTitle: groundedTitle,
                accessibilitySnapshot: capture.accessibilitySnapshot,
                screenshotReferenceID: "screen:\(capture.target.connectionGeneration):\(UUID().uuidString):\(capture.snapshotID ?? "window")",
                screenshotJPEGData: capture.screenshotData,
                screenshotMIMEType: capture.screenshotMIMEType,
                screenshotCoordinateSpace: .windowPixels,
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
                    screenshotReferenceID: "screen:failed:\(UUID().uuidString)",
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

    func resolveTaskWindow(
        worker: ScreenWorkerHandle,
        targetHint: ScreenTargetHint? = nil
    ) async -> (context: ScreenContext, target: ScreenWindowTarget?) {
        let resolvedHint = targetHint ?? currentTargetHint()
        if let screenContextLoader {
            return await screenContextLoader(worker, resolvedHint)
        }
        guard let target = try? await worker.probeTarget(resolvedHint) else {
            return (ScreenContext(frontAppBundleID: resolvedHint.bundleID, frontWindowTitle: resolvedHint.windowTitle), nil)
        }
        return (
            ScreenContext(
                frontAppBundleID: target.bundleID,
                frontWindowTitle: target.title,
                screenshotReferenceID: "screen:\(target.connectionGeneration):\(UUID().uuidString):window"
            ),
            target
        )
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
        guard let bundleID else { return NSWorkspace.shared.frontmostApplication?.processIdentifier }
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        return (applications.first(where: { $0.isActive }) ?? applications.first)?.processIdentifier
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

    func pinInvocationTarget(_ target: ScreenTargetHint? = nil) {
        invocationTarget = target ?? Self.frontmostTarget()
    }

    func clearInvocationTarget() {
        invocationTarget = nil
    }

    func pinInvocationTargetIfNeeded() {
        if invocationTarget == nil { pinInvocationTarget() }
    }

    func currentTargetHint() -> ScreenTargetHint {
        if let window = spatialSelection()?.window {
            return ScreenTargetHint(
                bundleID: window.appBundleID,
                processID: processID(for: window.appBundleID),
                windowTitle: window.title
            )
        }
        return invocationTarget ?? Self.frontmostTarget()
    }

    func presentationTarget() -> ScreenTargetHint? {
        let foreground = Self.frontmostTarget()
        let target = foreground.processID == ProcessInfo.processInfo.processIdentifier ? currentTargetHint() : foreground
        guard target.processID != ProcessInfo.processInfo.processIdentifier else { return nil }
        return target
    }

    static func availableTargets() -> [ScreenTargetHint] {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let targets: [ScreenTargetHint] = windows.compactMap { window in
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? Int32,
                  pid != ProcessInfo.processInfo.processIdentifier,
                  let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular,
                  let bundleID = app.bundleIdentifier,
                  let id = window[kCGWindowNumber as String] as? NSNumber,
                  let title = window[kCGWindowName as String] as? String,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return ScreenTargetHint(bundleID: bundleID, processID: pid, windowID: id.int64Value,
                windowTitle: title)
        }
        let represented = Set(targets.compactMap(\.processID))
        let applications = NSWorkspace.shared.runningApplications.compactMap { app -> ScreenTargetHint? in
            guard app.activationPolicy == .regular,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  !represented.contains(app.processIdentifier),
                  let bundleID = app.bundleIdentifier else { return nil }
            return ScreenTargetHint(bundleID: bundleID, processID: app.processIdentifier)
        }
        return targets + applications
    }

    private static func frontmostTarget() -> ScreenTargetHint {
        let application = NSWorkspace.shared.frontmostApplication
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        let window = windows?.first {
            ($0[kCGWindowOwnerPID as String] as? Int32) == application?.processIdentifier
                && ($0[kCGWindowLayer as String] as? Int) == 0
        }
        return ScreenTargetHint(
            bundleID: application?.bundleIdentifier,
            processID: application?.processIdentifier,
            windowID: (window?[kCGWindowNumber as String] as? NSNumber)?.int64Value,
            windowTitle: window?[kCGWindowName as String] as? String
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
