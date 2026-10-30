import Foundation
import PerryCore

public struct ScreenContext: Sendable {
    public enum ScreenshotCoordinateSpace: String, Sendable {
        case screenPoints
        case windowPixels
    }

    public let frontAppBundleID: String?
    public let frontWindowTitle: String?
    public let accessibilitySnapshot: String?
    public let screenshotReferenceID: String?
    public let screenshotJPEGData: Data?
    public let screenshotMIMEType: String
    public let screenshotCoordinateSpace: ScreenshotCoordinateSpace
    public let spatialRegionDescription: String?
    public let appSkillContext: String?
    public let memoryContext: String?
    public let remoteIntegrationContext: String?
    public let targetWindow: ExecutableAction.WindowIdentity?

    public init(
        frontAppBundleID: String? = nil,
        frontWindowTitle: String? = nil,
        accessibilitySnapshot: String? = nil,
        screenshotReferenceID: String? = nil,
        screenshotJPEGData: Data? = nil,
        screenshotMIMEType: String = "image/jpeg",
        screenshotCoordinateSpace: ScreenshotCoordinateSpace = .screenPoints,
        spatialRegionDescription: String? = nil,
        appSkillContext: String? = nil,
        memoryContext: String? = nil,
        remoteIntegrationContext: String? = nil,
        targetWindow: ExecutableAction.WindowIdentity? = nil
    ) {
        self.frontAppBundleID = frontAppBundleID
        self.frontWindowTitle = frontWindowTitle
        self.accessibilitySnapshot = accessibilitySnapshot
        self.screenshotReferenceID = screenshotReferenceID
        self.screenshotJPEGData = screenshotJPEGData
        self.screenshotMIMEType = screenshotMIMEType
        self.screenshotCoordinateSpace = screenshotCoordinateSpace
        self.spatialRegionDescription = spatialRegionDescription
        self.appSkillContext = appSkillContext
        self.memoryContext = memoryContext
        self.remoteIntegrationContext = remoteIntegrationContext
        self.targetWindow = targetWindow
    }

    public static let empty = ScreenContext()
}

public struct StepResult: Sendable, Equatable {
    public let stepID: String
    public let success: Bool
    public let message: String

    public init(stepID: String, success: Bool, message: String) {
        self.stepID = stepID
        self.success = success
        self.message = message
    }
}

public enum VerificationStatus: Sendable, Equatable {
    case notRequired
    case verified(evidence: String)
    case unverified(reason: String)
}

public protocol TypedActionVerifier: Sendable {
    func verify(approvedAction: ApprovedExecutableAction, result: ActionExecutionResult, context: ScreenContext) async -> VerificationStatus
}

public struct NoOpTypedActionVerifier: TypedActionVerifier {
    public init() {}
    public func verify(approvedAction: ApprovedExecutableAction, result: ActionExecutionResult, context: ScreenContext) async -> VerificationStatus {
        .notRequired
    }
}

public enum TypedDoEvent: Sendable {
    case actionStarted(index: Int, action: ExecutableAction, tier: TrustTier)
    case verification(action: ExecutableAction, status: VerificationStatus)
}

public enum DoEvent: Sendable {
    case planned(steps: Int)
    case started
    case paused
    case resumed
    case steered(String)
    case confirmationRequested(ConfirmationRequest)
    case confirmationAccepted(UUID)
    case completed(stepsRun: Int)
    case stopped(reason: String)
    case failed(stepSummary: String, reason: String)
}

public struct PlanError: Error, CustomStringConvertible, LocalizedError {
    public let message: String
    public var description: String { "plan error: \(message)" }
    public var errorDescription: String? { description }

    public init(message: String) {
        self.message = message
    }
}

public struct ExecutionError: Error, CustomStringConvertible, LocalizedError {
    public let message: String
    public var description: String { "execution error: \(message)" }
    public var errorDescription: String? { description }

    public init(message: String) {
        self.message = message
    }
}
