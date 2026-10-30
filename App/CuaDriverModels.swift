import Foundation
import PerryGuide

struct CuaDriverHealth: Sendable, Equatable {
    let ready: Bool
    let summary: String
}

struct CuaTargetHint: Sendable, Equatable {
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

struct CuaWindowTarget: Sendable, Equatable {
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

    var hint: CuaTargetHint {
        CuaTargetHint(bundleID: bundleID, processID: processID, windowID: windowID, windowTitle: title)
    }
}

struct CuaCapturedWindow: Sendable {
    let target: CuaWindowTarget
    let screenshotData: Data
    let screenshotMIMEType: String
    let accessibilitySnapshot: String?
    let accessibilitySnapshotModel: AXSnapshot?
    let snapshotID: String?
    var elementDetails: [String: CuaElementDetail] = [:]
    var treeComplete = true
}

struct CuaElementDetail: Sendable, Equatable {
    let value: String?
    let pressable: Bool
}

#if DEBUG
extension CuaCapturedWindow {
    static func debugFixture(snapshot: AXSnapshot) -> CuaCapturedWindow {
        CuaCapturedWindow(
            target: CuaWindowTarget(
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

enum CuaDriverError: Error, LocalizedError, Equatable {
    case unavailable
    case processExited
    case requestTimedOut
    case protocolFailure(String)
    case toolRejected(String)
    case noTargetWindow
    case noScreenshot
    case targetNotFound
    case targetSessionMismatch
    case protectedTarget
    case unsupportedAction
    case terminationUnconfirmed
    case targetMismatch
    case actionUnanswered

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Screen control couldn’t start. Open Settings > Brain to fix it."
        case .processExited:
            return "Screen control stopped before it finished. Try again."
        case .requestTimedOut, .protocolFailure:
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
        case .protectedTarget:
            return "I’ll not look at or use a window that holds sensitive information."
        case .unsupportedAction:
            return "I can’t do that in this window."
        case .terminationUnconfirmed:
            return "I couldn’t confirm that screen control stopped."
        case .targetMismatch:
            return "The window changed since I made the plan, so I stopped instead of acting on the wrong window."
        case .actionUnanswered:
            return "The app didn’t answer in time, so screen control restarted. The action may or may not have happened: look at the window again before the next step."
        }
    }

    var isStaleTarget: Bool {
        switch self {
        case .toolRejected(let detail), .protocolFailure(let detail):
            let normalized = detail.lowercased()
            return normalized.contains("stale") || normalized.contains("snapshot")
        default:
            return false
        }
    }

    var isTargetFact: Bool {
        switch self {
        case .targetMismatch, .targetNotFound, .noTargetWindow, .protectedTarget, .unsupportedAction, .toolRejected:
            return true
        default:
            return false
        }
    }

    var isRespawnableReadFailure: Bool {
        self == .processExited || self == .requestTimedOut
    }
}
