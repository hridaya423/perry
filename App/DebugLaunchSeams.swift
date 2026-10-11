#if DEBUG
import AppKit
import Foundation
import PerryGuide
import PerryRuntimes

typealias FullGuideCaptureLoader = @MainActor (CuaWorkerHandle, CuaTargetHint?) async throws -> CuaCapturedWindow
typealias FullGuideContinuationBarrier = @MainActor (UUID) async -> Void
typealias FullGuidePlanner = @MainActor (String, GuideObservation, GuideContext) async throws -> [GuideStep]
typealias FinalizationPersistenceBarrier = @Sendable () async -> Void

/// Fixture seams the DEBUG harness init and `--perry-debug-*` launch
/// arguments inject into the composition root — each replaces a production
/// collaborator so fixtures stay deterministic. One bag so AppController
/// doesn't carry a dozen properties that exist only for tests.
struct DebugLaunchSeams {
    var storageDirectory: URL?
    var runtimeInventoryLoader: RuntimeCatalog.InventoryLoader?
    var permissionSnapshotLoader: EnvironmentProbe.PermissionSnapshotLoader?
    var cuaHealthLoader: EnvironmentProbe.CuaHealthLoader?
    var screenContextLoader: EnvironmentProbe.ScreenContextLoader?
    var fullGuideCaptureLoader: FullGuideCaptureLoader?
    var fullGuideContinuationBarrier: FullGuideContinuationBarrier?
    var fullGuidePlanner: FullGuidePlanner?
    var guidePlanner: (any GuidePlanner)?
    var finalizationBarrier: FinalizationBarrier?
    var typedVerifier: (any TypedActionVerifier)?
    var confirmer: (any Confirmer)?
    var askUser: (@Sendable (String, [String]) async throws -> Void)?

    /// `--perry-debug-*` launch arguments → seams. Parsed once in the
    /// production init; the harness init takes seams explicitly.
    static func launch(arguments: [String]) -> DebugLaunchSeams {
        var seams = DebugLaunchSeams()
        if PerryDebugLaunchSurface(arguments: arguments) == .backgroundTasksStorageError,
           let index = arguments.firstIndex(of: "--perry-debug-storage-directory"),
           arguments.indices.contains(index + 1),
           !arguments[index + 1].isEmpty {
            let path = arguments[index + 1]
            var isDirectory = ObjCBool(false)
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                seams.storageDirectory = URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        // `--perry-debug-runtimes none` reports an inventory with only
        // Automatic + the planning-only local planner, so UI captures can
        // exercise the panel's inline no-runtime recovery deterministically.
        if let index = arguments.firstIndex(of: "--perry-debug-runtimes"),
           arguments.indices.contains(index + 1),
           arguments[index + 1] == "none" {
            seams.runtimeInventoryLoader = { workingDirectory in
                try await RuntimeInventoryInspector(
                    readDirectProvider: { nil },
                    commandLineProviders: []
                ).inspect(workingDirectory: workingDirectory)
            }
        }
        return seams
    }
}
#endif

#if DEBUG
extension AppController {
    func debugSetMaintenanceFixture(
        skipEraseConfirmation: Bool,
        barrier: (@MainActor () async throws -> Void)?
    ) {
        maintenance.debugSetFixture(skipEraseConfirmation: skipEraseConfirmation, barrier: barrier)
    }

    func debugInvokeWipeDataAction() {
        requestCompleteErasure()
    }

    var debugMaintenanceOwnerHeld: Bool {
        maintenance.isUnderMaintenance
    }

    /// Test seam for the dictated-command path — identical to what
    /// VoiceController's dispatch hook delivers after wake word/dictation.
    func debugDispatch(_ text: String) {
        commandRouter.route(commandText: text)
    }

    /// Seeds the History fixture and opens History for the capture lane.
    func debugShowHistoryFixture() {
        Task { @MainActor in
            for entry in PerryDebugLaunchSurface.historyEntries() {
                await transcriptStore.append(entry)
            }
            showHistory()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Applies a deterministic `DebugStateFixture` — see DebugStateFixtures.swift.
    func applyDebugStateFixture(_ fixture: DebugStateFixture) {
        switch fixture {
        case .permissionDenied:
            onboarding.runDenied()
        case .approvalOrange, .approvalRed:
            guard let card = fixture.intentCard else { return }
            intentCards.showFixture(card)
        default:
            if let state = fixture.sessionState {
                sessionController.debugSet(state)
            }
            if let status = fixture.statusText {
                sessionStatus = status
            }
            showPanel()
        }
    }
}
#endif
