import Foundation
import PerryCore

public struct RuntimeCapabilities: Sendable {
    public var guiGrounding: Bool
    public var fileIO: Bool
    public var browser: Bool
    public var latencyClass: LatencyClass

    public enum LatencyClass: String, Sendable {
        case fast
        case medium
        case slow
    }

    public init(
        guiGrounding: Bool = false,
        fileIO: Bool = false,
        browser: Bool = false,
        latencyClass: LatencyClass = .medium
    ) {
        self.guiGrounding = guiGrounding
        self.fileIO = fileIO
        self.browser = browser
        self.latencyClass = latencyClass
    }
}

public struct ScreenContext: Sendable {
    public let frontAppBundleID: String?
    public let frontWindowTitle: String?
    public let accessibilitySnapshot: String?
    public let screenshotReferenceID: String?

    public init(
        frontAppBundleID: String? = nil,
        frontWindowTitle: String? = nil,
        accessibilitySnapshot: String? = nil,
        screenshotReferenceID: String? = nil
    ) {
        self.frontAppBundleID = frontAppBundleID
        self.frontWindowTitle = frontWindowTitle
        self.accessibilitySnapshot = accessibilitySnapshot
        self.screenshotReferenceID = screenshotReferenceID
    }

    public static let empty = ScreenContext()
}

public struct Step: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case highlight
        case movePointer
        case typeText
        case clickControl
        case createFile
        case renameFile
        case moveToTrash
        case delegate
    }

    public let id: String
    public let kind: Kind
    public let summary: String
    public let payload: [String: String]

    public init(id: String = UUID().uuidString, kind: Kind, summary: String, payload: [String: String] = [:]) {
        self.id = id
        self.kind = kind
        self.summary = summary
        self.payload = payload
    }
}

public struct Plan: Sendable, Equatable {
    public let goal: String
    public let runtimeID: String
    public let steps: [Step]

    public init(goal: String, runtimeID: String, steps: [Step]) {
        self.goal = goal
        self.runtimeID = runtimeID
        self.steps = steps
    }
}

public struct ConsentHandle: Sendable, Equatable {
    public let stepID: String
    public let tier: TrustTier
    public let issuedAt: Date

    public init(stepID: String, tier: TrustTier, issuedAt: Date = Date()) {
        self.stepID = stepID
        self.tier = tier
        self.issuedAt = issuedAt
    }
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

public struct PlanError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { "plan error: \(message)" }
}

public struct ExecutionError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { "execution error: \(message)" }

    public init(message: String) {
        self.message = message
    }
}

public enum StepActionMapper {
    public static func descriptor(for step: Step, goal: String, targetAppBundleID: String?) -> ActionDescriptor {
        switch step.kind {
        case .highlight, .movePointer:
            return ActionDescriptor(kind: .highlightElement, targetAppBundleID: targetAppBundleID, summary: step.summary)
        case .typeText:
            return ActionDescriptor(kind: .typeText, targetAppBundleID: targetAppBundleID, summary: step.summary)
        case .clickControl:
            return ActionDescriptor(kind: .clickControl, targetAppBundleID: targetAppBundleID, summary: step.summary)
        case .createFile:
            return ActionDescriptor(kind: .createFile, targetAppBundleID: targetAppBundleID, summary: step.summary)
        case .renameFile:
            return ActionDescriptor(kind: .renameFile, targetAppBundleID: targetAppBundleID, summary: step.summary)
        case .moveToTrash:
            return ActionDescriptor(kind: .moveToTrash, targetAppBundleID: targetAppBundleID, summary: step.summary)
        case .delegate:
            return ActionDescriptor(kind: .runShellCommand, targetAppBundleID: targetAppBundleID, summary: "delegated task: \(goal)", pathInsideWorkspace: true)
        }
    }
}
