import Foundation
import PerryGuide
import Security

enum ScreenCodeIdentity: Sendable, Equatable {
    case appleDeveloperID(identifier: String, teamIdentifier: String)
    case unsignedOrAdHoc

    private static let developerIDRequirement = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"

    static func read(at url: URL) -> ScreenCodeIdentity? {
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(resolvedURL as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else {
            return nil
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(developerIDRequirement as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(
                  staticCode,
                  SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate),
                  requirement
              ) == errSecSuccess else {
            return nil
        }
        var signingInfo: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInfo
        ) == errSecSuccess,
              let signingInfo else {
            return nil
        }
        let values = signingInfo as NSDictionary
        guard let identifier = values[kSecCodeInfoIdentifier] as? String,
              !identifier.isEmpty,
              let teamIdentifier = values[kSecCodeInfoTeamIdentifier] as? String,
              !teamIdentifier.isEmpty else {
            return nil
        }
        return .appleDeveloperID(identifier: identifier, teamIdentifier: teamIdentifier)
    }

    static func isBundled(_ url: URL, inside hostBundleURL: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let hostComponents = hostBundleURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return resolved.count > hostComponents.count && resolved.starts(with: hostComponents)
    }
}

struct ScreenDriverHealth: Sendable, Equatable {
    let ready: Bool
    let summary: String
}

struct ScreenTargetHint: Sendable, Equatable {
    let bundleID: String?
    let processID: Int32?
    let windowID: Int64?
    let windowTitle: String?

    init(
        bundleID: String? = nil,
        processID: Int32? = nil,
        windowID: Int64? = nil,
        windowTitle: String? = nil
    ) {
        self.bundleID = bundleID
        self.processID = processID
        self.windowID = windowID
        self.windowTitle = windowTitle
    }
}

struct ScreenWindowTarget: Sendable, Equatable {
    let bundleID: String
    let processID: Int32
    let windowID: Int64
    let connectionGeneration: UInt64
    let sessionID: String
    let title: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let zIndex: Int?
    let isOnScreen: Bool
    let isOnCurrentSpace: Bool

    var hint: ScreenTargetHint {
        ScreenTargetHint(bundleID: bundleID, processID: processID, windowID: windowID, windowTitle: title)
    }
}

struct ScreenCapturedWindow: Sendable {
    let target: ScreenWindowTarget
    let screenshotData: Data
    let screenshotMIMEType: String
    let accessibilitySnapshot: String?
    let accessibilitySnapshotModel: AXSnapshot?
    let snapshotID: String?
    var elementDetails: [String: ScreenElementDetail] = [:]
    var treeComplete = true
}

struct ScreenElementDetail: Sendable, Equatable {
    let value: String?
}

#if DEBUG
extension ScreenCapturedWindow {
    static func debugFixture(snapshot: AXSnapshot) -> ScreenCapturedWindow {
        ScreenCapturedWindow(
            target: ScreenWindowTarget(
                bundleID: snapshot.appBundleID,
                processID: 1,
                windowID: 1,
                connectionGeneration: 0,
                sessionID: "debug-fixture",
                title: snapshot.windowTitle,
                x: 0,
                y: 0,
                width: 800,
                height: 600,
                zIndex: 0,
                isOnScreen: true,
                isOnCurrentSpace: true
            ),
            screenshotData: Data(),
            screenshotMIMEType: "image/jpeg",
            accessibilitySnapshot: nil,
            accessibilitySnapshotModel: snapshot,
            snapshotID: "debug-fixture"
        )
    }
}
#endif

enum ScreenDriverError: Error, LocalizedError, Equatable {
    case unavailable
    case processExited
    case requestTimedOut
    case protocolFailure(String)
    case toolRejected(String)
    case noTargetWindow
    case noScreenshot
    case targetNotFound
    case staleTarget
    case targetSessionMismatch
    case protectedTarget
    case unsupportedAction
    case terminationUnconfirmed
    case targetMismatch
    case actionUnanswered
    case appBusy
    case windowNotInFront

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Screen control couldn’t start. Check that Accessibility and Screen Recording are on for Perry in System Settings."
        case .processExited:
            return "Screen control stopped before it finished. Try again."
        case .requestTimedOut:
            return "Screen control took too long to answer. Try again."
        case .protocolFailure:
            return "Screen control sent an answer I couldn’t read. Try again."
        case .toolRejected(let detail):
            return detail.isEmpty ? "Screen control refused that action." : detail
        case .noTargetWindow:
            return "I couldn’t tell which window to use. Click the window, then try again."
        case .noScreenshot:
            return "I couldn’t capture that window. Check that Screen Recording is on for Perry."
        case .targetNotFound:
            return "I couldn’t find that control in the window anymore."
        case .targetSessionMismatch:
            return "That control is from an earlier look at the screen. I need to look again."
        case .staleTarget:
            return "That control changed since I last looked. I need to look again."
        case .protectedTarget:
            return "I won’t look at or use a window that holds sensitive information."
        case .unsupportedAction:
            return "I can’t do that in this window."
        case .terminationUnconfirmed:
            return "I couldn’t confirm that screen control stopped."
        case .targetMismatch:
            return "The window changed since I made the plan, so I stopped instead of acting on the wrong window."
        case .actionUnanswered:
            return "The app didn’t answer in time, so screen control restarted. The action may or may not have happened: look at the window again before the next step."
        case .appBusy:
            return "The app took too long to answer, so I didn’t act. Try again."
        case .windowNotInFront:
            return "Keys only reach the window in front, so I didn’t press them. Bring that window forward, then try again."
        }
    }

    var isStaleTarget: Bool {
        switch self {
        case .staleTarget:
            return true
        case .toolRejected(let detail), .protocolFailure(let detail):
            let normalized = detail.lowercased()
            return normalized.contains("stale") || normalized.contains("snapshot")
        default:
            return false
        }
    }

    var isTargetFact: Bool {
        switch self {
        case .targetMismatch, .targetNotFound, .staleTarget, .noTargetWindow, .protectedTarget, .unsupportedAction, .toolRejected, .appBusy, .windowNotInFront:
            return true
        default:
            return false
        }
    }

    var isRespawnableReadFailure: Bool {
        self == .processExited || self == .requestTimedOut
    }
}
