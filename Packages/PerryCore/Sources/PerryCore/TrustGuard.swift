import Foundation

public enum TrustTier: String, Codable, Sendable, Comparable {
    case green
    case yellow
    case orange
    case red

    private var rank: Int {
        switch self {
        case .green: return 0
        case .yellow: return 1
        case .orange: return 2
        case .red: return 3
        }
    }

    public static func < (lhs: TrustTier, rhs: TrustTier) -> Bool {
        lhs.rank < rhs.rank
    }
}

public enum ActionKind: String, Sendable, CaseIterable {
    case movePointer
    case highlightElement
    case readWindow
    case typeText
    case clickControl
    case createFile
    case renameFile
    case sendEmailOrMessage
    case moveToTrash
    case overwriteFile
    case emptyTrash
    case makePurchase
    case accessCredentials
    case runShellCommand
}

public struct ActionDescriptor: Sendable {
    public let kind: ActionKind
    public let targetAppBundleID: String?
    public let summary: String
    public let shellExecutablePath: String?
    public let pathInsideWorkspace: Bool

    public init(
        kind: ActionKind,
        targetAppBundleID: String? = nil,
        summary: String,
        shellExecutablePath: String? = nil,
        pathInsideWorkspace: Bool = true
    ) {
        self.kind = kind
        self.targetAppBundleID = targetAppBundleID
        self.summary = summary
        self.shellExecutablePath = shellExecutablePath
        self.pathInsideWorkspace = pathInsideWorkspace
    }
}

public struct WindowContext: Sendable {
    public let appBundleID: String
    public let title: String

    public init(appBundleID: String, title: String) {
        self.appBundleID = appBundleID
        self.title = title
    }
}

public enum GuardDecision: Equatable, Sendable {
    case allowAutonomous(tier: TrustTier)
    case requireConfirmation(tier: TrustTier, reason: String)
    case deny(reason: String)
}

public struct TrustGuard: Sendable {
    public static let defaultBlockedBundleIDs: Set<String> = [
        "com.apple.KeychainAccess",
        "com.agilebits.onepassword-osx",
        "com.agilebits.onepassword7",
        "com.lastpass.LastPass",
        "com.bitwarden.desktop",
        "com.dashlane.dashlanephonehome",
        "com.keepersecurity.KeeperDesktop",
    ]

    public static let defaultSensitiveTitleKeywords: Set<String> = [
        "checkout",
        "payment",
        "billing",
        "bank",
        "sign in",
        "log in",
        "password",
    ]

    public let blockedBundleIDs: Set<String>
    public let sensitiveTitleKeywords: Set<String>

    public init(
        blockedBundleIDs: Set<String> = TrustGuard.defaultBlockedBundleIDs,
        sensitiveTitleKeywords: Set<String> = TrustGuard.defaultSensitiveTitleKeywords
    ) {
        self.blockedBundleIDs = blockedBundleIDs
        self.sensitiveTitleKeywords = sensitiveTitleKeywords
    }

    public func classify(_ action: ActionDescriptor) -> TrustTier {
        switch action.kind {
        case .movePointer, .highlightElement, .readWindow:
            return .green
        case .typeText, .clickControl, .createFile, .renameFile:
            return .yellow
        case .sendEmailOrMessage, .moveToTrash, .overwriteFile:
            return .orange
        case .emptyTrash, .makePurchase, .accessCredentials:
            return .red
        case .runShellCommand:
            return action.pathInsideWorkspace ? .yellow : .red
        }
    }

    public func isWindowBlocked(_ window: WindowContext?) -> Bool {
        guard let window else { return false }
        if blockedBundleIDs.contains(window.appBundleID.lowercased()) {
            return true
        }
        let title = window.title.lowercased()
        return sensitiveTitleKeywords.contains { title.contains($0) }
    }

    public func decide(action: ActionDescriptor, targetWindow: WindowContext?) -> GuardDecision {
        if isWindowBlocked(targetWindow) {
            return .deny(reason: "target window is on the blocked list")
        }
        let tier = classify(action)
        switch tier {
        case .green, .yellow:
            return .allowAutonomous(tier: tier)
        case .orange:
            return .requireConfirmation(tier: tier, reason: "irreversible action needs one confirmation")
        case .red:
            return .requireConfirmation(
                tier: tier,
                reason: "high-risk action requires explicit approval"
            )
        }
    }
}
