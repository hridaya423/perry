import Foundation
import PerryGuide
import PerryRuntimes

struct LaunchOverrides {
    var storageDirectory: URL?
    var taskCoordinator: TaskCoordinator?
    var notifier: (any AppNotificationClient)?
    var runtimeSetupLoader: RuntimeCatalog.SetupLoader?
    var permissionSnapshotLoader: EnvironmentProbe.PermissionSnapshotLoader?
    var screenHealthLoader: EnvironmentProbe.ScreenHealthLoader?
    var screenContextLoader: EnvironmentProbe.ScreenContextLoader?
    var fullGuideCaptureLoader: GuideSessionCoordinator.FullGuideCaptureLoader?
    var fullGuideContinuationBarrier: GuideSessionCoordinator.FullGuideContinuationBarrier?
    var guidePlanner: (any GuidePlanner)?
    var finalizationBarrier: FinalizationBarrier?
    var finalizationPersistenceBarrier: (@Sendable () async -> Void)?
    var typedVerifier: (any TypedActionVerifier)?
    var confirmer: (any Confirmer)?
    var askUser: (@Sendable (String, [String]) async throws -> Void)?
}
