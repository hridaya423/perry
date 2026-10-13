import AppKit
import Darwin
import Foundation
import Security
import PerryCore
import PerryGuide
import PerryRuntimes

enum CuaCodeIdentity: Sendable, Equatable {
    case appleDeveloperID(identifier: String, teamIdentifier: String)
    case unsignedOrAdHoc
}

struct CuaDriverConfiguration: Sendable {
    let executableURL: URL
    var capabilityManifestURL: URL
    let hostBundleID: String

    private static let driverRequirement = "identifier \"cua-driver\" and anchor apple generic and certificate leaf[subject.OU] = \"YCK386LBJ7\""
    private static let developerIDRequirement = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"

    static func discover(
        environment _: [String: String] = [:],
        fileManager: FileManager = .default,
        bundle: Bundle = .main,
        userDefaults: UserDefaults = .standard,
        identityVerifier: (URL) -> Bool = { verifyIdentity(at: $0) },
        codeIdentityReader: (URL) -> CuaCodeIdentity? = { readDeveloperIDIdentity(at: $0) }
    ) -> CuaDriverConfiguration? {
        let registeredURL = userDefaults.string(forKey: PerryPreferences.$cuaDriverPath.key).flatMap { value -> URL? in
            let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, path.hasPrefix("/") else { return nil }
            return URL(fileURLWithPath: path)
        }
        let bundledURL = bundle.url(forResource: "cua-driver", withExtension: nil, subdirectory: "CuaDriver/bin")
        guard let manifestURL = bundle.url(
            forResource: "capabilities",
            withExtension: "yaml",
            subdirectory: "CuaDriver"
        ) else {
            return nil
        }

        let hostBundleURL = bundle.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let capabilityManifestURL = manifestURL.resolvingSymlinksInPath().standardizedFileURL
        guard isResolvedBundledPath(capabilityManifestURL, inside: hostBundleURL),
              fileManager.isReadableFile(atPath: capabilityManifestURL.path) else {
            return nil
        }
        let hostBundleID = bundle.bundleIdentifier ?? "dev.perry.Perry"

        if let registeredURL {
            let executableURL = registeredURL.resolvingSymlinksInPath().standardizedFileURL
            guard fileManager.isExecutableFile(atPath: executableURL.path),
                  identityVerifier(executableURL) else {
                return bundledConfiguration(
                    bundledURL,
                    hostBundleURL: hostBundleURL,
                    hostBundleID: hostBundleID,
                    capabilityManifestURL: capabilityManifestURL,
                    fileManager: fileManager,
                    identityVerifier: identityVerifier,
                    codeIdentityReader: codeIdentityReader
                )
            }
            return CuaDriverConfiguration(
                executableURL: executableURL,
                capabilityManifestURL: capabilityManifestURL,
                hostBundleID: hostBundleID
            )
        }

        return bundledConfiguration(
            bundledURL,
            hostBundleURL: hostBundleURL,
            hostBundleID: hostBundleID,
            capabilityManifestURL: capabilityManifestURL,
            fileManager: fileManager,
            identityVerifier: identityVerifier,
            codeIdentityReader: codeIdentityReader
        )
    }

    private static func verifyIdentity(at url: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else {
            return false
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(driverRequirement as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement else {
            return false
        }
        return SecStaticCodeCheckValidity(staticCode, SecCSFlags(), requirement) == errSecSuccess
    }

    private static func readDeveloperIDIdentity(at url: URL) -> CuaCodeIdentity? {
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

    static func bundledDriverIsAllowed(
        driverURL: URL,
        hostBundleURL: URL,
        upstreamIdentityVerified: Bool,
        hostIdentity: CuaCodeIdentity?,
        driverIdentity: CuaCodeIdentity?
    ) -> Bool {
        guard isResolvedBundledPath(driverURL, inside: hostBundleURL) else { return false }
        if upstreamIdentityVerified {
            return true
        }
        guard case let .appleDeveloperID(_, hostTeam) = hostIdentity,
              case let .appleDeveloperID(identifier, driverTeam) = driverIdentity,
              !hostTeam.isEmpty,
              identifier == "cua-driver",
              !driverTeam.isEmpty,
              driverTeam == hostTeam else {
            return false
        }
        return true
    }

    private static func bundledConfiguration(
        _ bundledURL: URL?,
        hostBundleURL: URL,
        hostBundleID: String,
        capabilityManifestURL: URL,
        fileManager: FileManager,
        identityVerifier: (URL) -> Bool,
        codeIdentityReader: (URL) -> CuaCodeIdentity?
    ) -> CuaDriverConfiguration? {
        guard let bundledURL else { return nil }
        let executableURL = bundledURL.resolvingSymlinksInPath().standardizedFileURL
        guard fileManager.isExecutableFile(atPath: executableURL.path),
              isResolvedBundledPath(executableURL, inside: hostBundleURL) else {
            return nil
        }
        let upstreamIdentityVerified = identityVerifier(executableURL)
        let hostIdentity = upstreamIdentityVerified ? nil : codeIdentityReader(hostBundleURL)
        let driverIdentity = upstreamIdentityVerified ? nil : codeIdentityReader(executableURL)
        guard bundledDriverIsAllowed(
            driverURL: executableURL,
            hostBundleURL: hostBundleURL,
            upstreamIdentityVerified: upstreamIdentityVerified,
            hostIdentity: hostIdentity,
            driverIdentity: driverIdentity
        ) else {
            return nil
        }
        return CuaDriverConfiguration(
            executableURL: executableURL,
            capabilityManifestURL: capabilityManifestURL,
            hostBundleID: hostBundleID
        )
    }

    private static func isResolvedBundledPath(_ driverURL: URL, inside hostBundleURL: URL) -> Bool {
        let resolvedDriverURL = driverURL.resolvingSymlinksInPath().standardizedFileURL
        let resolvedHostBundleURL = hostBundleURL.resolvingSymlinksInPath().standardizedFileURL
        let hostComponents = resolvedHostBundleURL.pathComponents
        return resolvedDriverURL.pathComponents.count > hostComponents.count
            && resolvedDriverURL.pathComponents.starts(with: hostComponents)
    }
}

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
    fileprivate let sessionID: String
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

    fileprivate init(
        bundleID: String,
        processID: Int32,
        windowID: Int64,
        connectionGeneration: UInt64,
        sessionID: String,
        title: String,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        zIndex: Int?,
        isOnScreen: Bool,
        isOnCurrentSpace: Bool
    ) {
        self.bundleID = bundleID
        self.processID = processID
        self.windowID = windowID
        self.connectionGeneration = connectionGeneration
        self.sessionID = sessionID
        self.title = title
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.zIndex = zIndex
        self.isOnScreen = isOnScreen
        self.isOnCurrentSpace = isOnCurrentSpace
    }
}

struct CuaCapturedWindow: Sendable {
    let target: CuaWindowTarget
    let screenshotData: Data
    let screenshotMIMEType: String
    let accessibilitySnapshot: String?
    let accessibilitySnapshotModel: AXSnapshot?
    let snapshotID: String?
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

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Cua Driver is not installed or could not be started."
        case .processExited:
            return "Cua Driver exited before completing the request."
        case .protocolFailure(let detail):
            return "Cua Driver protocol failure: \(detail)"
        case .toolRejected(let detail):
            return detail.isEmpty ? "Cua Driver refused the action." : detail
        case .noTargetWindow:
            return "Cua Driver could not identify the target window."
        case .noScreenshot:
            return "Cua Driver returned no target-window screenshot."
        case .targetNotFound:
            return "Cua Driver could not find the requested UI target."
        case .targetSessionMismatch:
            return "Cua Driver target belongs to a different session."
        case .protectedTarget:
            return "Perry refused to inspect or operate a sensitive window."
        case .unsupportedAction:
            return "Cua Driver does not support this Perry action."
        case .terminationUnconfirmed:
            return "Cua Driver could not confirm worker termination."
        case .targetMismatch:
            return "The target window changed since the plan was made, so Perry stopped instead of acting on the wrong window."
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
}

private struct CuaToolResult: Sendable {
    let structuredData: Data?
    let text: String
    let images: [Data]
    let imageMIMEType: String?
    let isError: Bool
}

private struct CuaConnectionState {
    let generation: UInt64
    let process: Process
    let inputHandle: FileHandle
    let outputHandle: FileHandle
    var initializationTask: Task<Void, Error>?
}

private struct CuaOwnedProcess {
    let process: Process
    let processGroup: pid_t?

    var hasExited: Bool {
        guard !process.isRunning else { return false }
        guard let processGroup else { return false }
        return kill(-processGroup, 0) == -1 && errno == ESRCH
    }

    func signal(_ signal: Int32) throws {
        let target: pid_t
        if let processGroup {
            target = -processGroup
        } else {
            guard process.isRunning else { return }
            target = process.processIdentifier
        }
        guard kill(target, signal) == 0 || errno == ESRCH else {
            throw CuaDriverError.terminationUnconfirmed
        }
    }
}

private struct CuaPendingRequest {
    let generation: UInt64
    let continuation: CheckedContinuation<Data, Error>
}

private struct CuaSessionState: Sendable {
    let generation: UInt64
    let target: CuaWindowTarget
    let snapshotID: String?
    let elementLabels: [String: String]
}

private enum CuaConfigurationSource {
    case discover
    case resolved(CuaDriverConfiguration?)
}

actor CuaDriverClient {
    private static let requestTimeout: TimeInterval = 15

    private let allowsRestart: Bool
    private var configurationSource: CuaConfigurationSource
    private var connection: CuaConnectionState?
    private var readBuffers: [UInt64: Data] = [:]
    private var nextConnectionGeneration: UInt64 = 0
    private var nextRequestID = 1
    private var pending: [Int: CuaPendingRequest] = [:]
    private var lastCleanupError: Error?
    private var startedSessions: [String: UInt64] = [:]
    private var sessionStates: [String: CuaSessionState] = [:]
    private var ownedProcesses: [UInt64: CuaOwnedProcess] = [:]
    private var retired = false
    private var retirementTask: Task<Void, Error>?

    init(allowsRestart: Bool = true) {
        self.allowsRestart = allowsRestart
        configurationSource = .discover
    }

    init(configuration: CuaDriverConfiguration?, allowsRestart: Bool = true) {
        self.allowsRestart = allowsRestart
        configurationSource = .resolved(configuration)
    }

    func health() async -> CuaDriverHealth {
        guard let configuration = resolvedConfiguration() else {
            return CuaDriverHealth(
                ready: false,
                summary: "Cua Driver is unavailable. Set a verified executable path in Settings or use the signed bundled driver."
            )
        }
        do {
            try await ensureStarted()
            let result = try await callTool(name: "check_permissions", arguments: [:])
            let values = result.structuredValue
            let accessibility = values?["accessibility"] as? Bool ?? false
            let screenRecording = values?["screen_recording"] as? Bool ?? false
            let source = values?["source"] as? [String: Any]
            let attribution = source?["attribution"] as? String
            let embedded = source?["embedded"] as? Bool ?? false
            guard attribution == "host", embedded else {
                return CuaDriverHealth(
                    ready: false,
                    summary: "Cua Driver did not confirm Perry as its embedded permission host."
                )
            }
            guard accessibility && screenRecording else {
                return CuaDriverHealth(
                    ready: false,
                    summary: "Cua Driver needs Accessibility and Screen Recording permission in System Settings."
                )
            }
            return CuaDriverHealth(
                ready: true,
                summary: "Cua Driver is ready at \(configuration.executableURL.path)."
            )
        } catch {
            return CuaDriverHealth(
                ready: false,
                summary: "Cua Driver health check failed: \(error.localizedDescription)"
            )
        }
    }

    func target(for sessionID: String) -> CuaWindowTarget? {
        guard let state = sessionStates[sessionID], state.generation == connection?.generation else { return nil }
        return state.target
    }

    func capture(target hint: CuaTargetHint?, sessionID: String) async throws -> CuaCapturedWindow {
        let resolvedTarget = try await resolveTarget(hint, sessionID: sessionID)
        return try await capture(resolvedTarget: resolvedTarget, sessionID: sessionID)
    }

    func resolveTarget(_ hint: CuaTargetHint?, sessionID: String) async throws -> CuaWindowTarget {
        sessionStates[sessionID] = nil
        let generation = try await ensureSession(sessionID)
        let windows = try await listWindows(generation: generation, sessionID: sessionID)
        let target = selectTarget(from: windows, hint: hint)
        guard let target else {
            throw CuaDriverError.noTargetWindow
        }
        try ensureTargetAllowed(target)
        guard connection?.generation == generation,
              startedSessions[sessionID] == generation else {
            throw CuaDriverError.processExited
        }
        return target
    }

    func capture(resolvedTarget: CuaWindowTarget, sessionID: String, includeScreenshot: Bool = true) async throws -> CuaCapturedWindow {
        try Task.checkCancellation()
        let generation = try validateResolvedTarget(resolvedTarget, sessionID: sessionID)
        let state = try await callTool(
            name: "get_window_state",
            arguments: [
                "pid": Int(resolvedTarget.processID),
                "window_id": resolvedTarget.windowID,
                "include_screenshot": includeScreenshot,
                "max_elements": 300,
                "max_depth": 12,
                "session": sessionID,
            ],
            generation: generation
        )
        let screenshotData = state.images.first ?? Data()
        if includeScreenshot, screenshotData.isEmpty {
            throw CuaDriverError.noScreenshot
        }
        guard connection?.generation == generation,
              startedSessions[sessionID] == generation else {
            throw CuaDriverError.processExited
        }
        let structuredValue = state.structuredValue
        let snapshotID = structuredValue?["snapshot_id"] as? String
        sessionStates[sessionID] = CuaSessionState(
            generation: generation,
            target: resolvedTarget,
            snapshotID: snapshotID,
            elementLabels: elementLabels(from: structuredValue)
        )
        return CuaCapturedWindow(
            target: resolvedTarget,
            screenshotData: screenshotData,
            screenshotMIMEType: state.imageMIMEType ?? "image/png",
            accessibilitySnapshot: formattedAccessibilitySnapshot(from: state.structuredValue),
            accessibilitySnapshotModel: guideSnapshot(from: structuredValue, target: resolvedTarget),
            snapshotID: snapshotID
        )
    }

    func execute(_ action: ComputerAction, sessionID: String) async throws -> StepResult {
        try Task.checkCancellation()
        _ = try await ensureSession(sessionID)
        let state = try await refreshSessionTarget(sessionID)
        if let expected = action.expectedWindow {
            let target = state.target
            guard target.processID == expected.processID,
                  target.windowID == Int64(expected.windowID),
                  target.bundleID.lowercased() == expected.bundleID.lowercased(),
                  target.connectionGeneration == expected.connectionGeneration else {
                throw CuaDriverError.targetMismatch
            }
        }
        switch action.operation {
        case .click(let target):
            let result = try await performAction(
                name: "click",
                target: target,
                state: state,
                sessionID: sessionID
            )
            return StepResult(stepID: action.stepID, success: true, message: result.text.isEmpty ? "Cua clicked the requested target." : result.text)
        case .typeText(let text, let target):
            var arguments = try await actionArguments(for: target, state: state, sessionID: sessionID)
            arguments["text"] = text
            let result: CuaToolResult
            do {
                result = try await callTool(name: "type_text", arguments: arguments)
            } catch let error as CuaDriverError where error.isStaleTarget {
                var refreshedArguments = try await actionArguments(for: target, state: state, sessionID: sessionID)
                refreshedArguments["text"] = text
                result = try await callTool(name: "type_text", arguments: refreshedArguments)
            }
            return StepResult(stepID: action.stepID, success: true, message: result.text.isEmpty ? "Cua entered the requested text." : result.text)
        case .rightClick(let target):
            let result = try await performAction(
                name: "right_click",
                target: target,
                state: state,
                sessionID: sessionID
            )
            return StepResult(stepID: action.stepID, success: true, message: result.text.isEmpty ? "Cua opened the target context menu." : result.text)
        case .doubleClick(let target):
            let result = try await performAction(
                name: "double_click",
                target: target,
                state: state,
                sessionID: sessionID
            )
            return StepResult(stepID: action.stepID, success: true, message: result.text.isEmpty ? "Cua double-clicked the requested target." : result.text)
        case .scroll(let direction, let amount, let by, let target):
            var additionalArguments: [String: Any] = ["direction": direction.rawValue, "amount": amount]
            if let by { additionalArguments["by"] = by }
            let result = try await performAction(
                name: "scroll",
                target: target,
                state: state,
                sessionID: sessionID,
                requiresTarget: false,
                additionalArguments: additionalArguments
            )
            return StepResult(stepID: action.stepID, success: true, message: result.text.isEmpty ? "Cua scrolled \(direction.rawValue)." : result.text)
        case .pressKey(let key, let modifiers, let target):
            var additionalArguments: [String: Any] = ["key": key]
            if let modifiers { additionalArguments["modifiers"] = modifiers }
            let result = try await performAction(
                name: "press_key",
                target: target,
                state: state,
                sessionID: sessionID,
                requiresTarget: false,
                additionalArguments: additionalArguments
            )
            return StepResult(stepID: action.stepID, success: true, message: result.text.isEmpty ? "Cua pressed \(key)." : result.text)
        case .hotkey(let keys, let target):
            let result = try await performAction(
                name: "hotkey",
                target: target,
                state: state,
                sessionID: sessionID,
                requiresTarget: false,
                additionalArguments: ["keys": keys]
            )
            return StepResult(stepID: action.stepID, success: true, message: result.text.isEmpty ? "Cua pressed \(keys.joined(separator: "+"))." : result.text)
        case .drag(let from, let to, let duration, let steps):
            var arguments: [String: Any] = [
                "from_x": from.x,
                "from_y": from.y,
                "to_x": to.x,
                "to_y": to.y,
                "pid": Int(state.target.processID),
                "window_id": state.target.windowID,
                "session": sessionID,
                "delivery_mode": "background",
            ]
            if let duration {
                arguments["duration_ms"] = duration
            }
            if let steps {
                arguments["steps"] = steps
            }
            let result = try await callTool(name: "drag", arguments: arguments)
            return StepResult(stepID: action.stepID, success: true, message: result.text.isEmpty ? "Cua dragged the requested target." : result.text)
        }
    }

    func insertText(_ text: String, target hint: CuaTargetHint, sessionID: String) async throws -> CuaWindowTarget {
        guard !text.isEmpty else {
            throw CuaDriverError.toolRejected("Text insertion requires non-empty text.")
        }
        let resolvedTarget = try await resolveTarget(hint, sessionID: sessionID)
        return try await insertText(text, resolvedTarget: resolvedTarget, sessionID: sessionID)
    }

    func insertText(_ text: String, resolvedTarget: CuaWindowTarget, sessionID: String) async throws -> CuaWindowTarget {
        guard !text.isEmpty else {
            throw CuaDriverError.toolRejected("Text insertion requires non-empty text.")
        }
        try Task.checkCancellation()
        let generation = try validateResolvedTarget(resolvedTarget, sessionID: sessionID)
        let result = try await callTool(
            name: "type_text",
            arguments: [
                "text": text,
                "pid": Int(resolvedTarget.processID),
                "window_id": resolvedTarget.windowID,
                "session": sessionID,
                "delivery_mode": "background",
            ],
            generation: generation
        )
        guard Self.actionWasVerified(result.structuredValue) else {
            throw CuaDriverError.toolRejected("Cua could not independently confirm text insertion in the target field.")
        }
        let current = try await refreshResolvedTarget(resolvedTarget, sessionID: sessionID)
        guard current == resolvedTarget else {
            throw CuaDriverError.toolRejected("The target window changed before text insertion could be verified.")
        }
        sessionStates[sessionID] = CuaSessionState(
            generation: current.connectionGeneration,
            target: current,
            snapshotID: nil,
            elementLabels: [:]
        )
        return current
    }

    static func verificationSucceeded(_ value: [String: Any]?) -> Bool {
        guard let value else { return false }
        if value["verified"] as? Bool == true
            || value["matched"] as? Bool == true
            || value["success"] as? Bool == true {
            return true
        }
        guard let status = value["status"] as? String else { return false }
        return status == "verified" || status == "matched" || status == "success"
    }

    static func actionWasVerified(_ value: [String: Any]?) -> Bool {
        guard let value else { return false }
        if value["verified"] as? Bool == true {
            return true
        }
        return value["effect"] as? String == "confirmed"
    }

    func endSession(_ sessionID: String) async {
        guard let generation = startedSessions[sessionID] else { return }
        do {
            _ = try await callTool(
                name: "end_session",
                arguments: ["session": sessionID],
                generation: generation
            )
        } catch {
            lastCleanupError = error
        }
        guard startedSessions[sessionID] == generation else { return }
        startedSessions[sessionID] = nil
        if sessionStates[sessionID]?.generation == generation {
            sessionStates[sessionID] = nil
        }
    }

    func shutdown() {
        let waiting = pending.values.map { $0.continuation }
        pending.removeAll()
        tearDownProcess(terminate: true)
        for continuation in waiting {
            continuation.resume(throwing: CuaDriverError.processExited)
        }
        startedSessions.removeAll()
        sessionStates.removeAll()
    }

    func retire() async throws {
        retired = true
        if let retirementTask {
            return try await retirementTask.value
        }
        let retirementTask = Task { try await self.finishRetirement() }
        self.retirementTask = retirementTask
        try await retirementTask.value
    }

    func reloadConfiguration() {
        guard !retired else { return }
        shutdown()
        configurationSource = .discover
        lastCleanupError = nil
    }

    private func ensureSession(_ sessionID: String) async throws -> UInt64 {
        try await ensureStarted()
        guard let generation = connection?.generation else { throw CuaDriverError.processExited }
        if startedSessions[sessionID] == generation { return generation }
        _ = try await callTool(
            name: "start_session",
            arguments: ["session": sessionID],
            generation: generation
        )
        guard connection?.generation == generation else { throw CuaDriverError.processExited }
        startedSessions[sessionID] = generation
        return generation
    }

    private func resolvedConfiguration() -> CuaDriverConfiguration? {
        switch configurationSource {
        case .discover:
            var configuration = CuaDriverConfiguration.discover()
            if var discovered = configuration,
               let supportDirectory = AppController.supportDirectory,
               let generated = CuaCapabilityManifest.materialize(
                   into: supportDirectory.appendingPathComponent("CuaDriver", isDirectory: true),
                   hostBundleID: discovered.hostBundleID
               ) {
                discovered.capabilityManifestURL = generated
                configuration = discovered
            }
            configurationSource = .resolved(configuration)
            return configuration
        case .resolved(let configuration):
            return configuration
        }
    }

    private func ensureStarted() async throws {
        try Task.checkCancellation()
        guard !retired else { throw CuaDriverError.processExited }
        reapExitedProcesses()
        if let connection {
            if connection.process.isRunning {
                if let initializationTask = connection.initializationTask {
                    try await initializationTask.value
                }
                try Task.checkCancellation()
                return
            }
            failConnection(generation: connection.generation, with: CuaDriverError.processExited)
        }
        guard allowsRestart || nextConnectionGeneration == 0 else {
            throw CuaDriverError.processExited
        }
        guard let configuration = resolvedConfiguration() else { throw CuaDriverError.unavailable }

        let generation = nextConnectionGeneration
        nextConnectionGeneration += 1
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = configuration.executableURL
        process.arguments = [
            "mcp",
            "--direct",
            "--embedded",
            "--host-bundle-id",
            configuration.hostBundleID,
        ]
        process.environment = Self.embeddedEnvironment(configuration: configuration)
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.standardError
        do {
            try process.run()
        } catch {
            throw CuaDriverError.unavailable
        }

        let pid = process.processIdentifier
        ownedProcesses[generation] = CuaOwnedProcess(
            process: process,
            processGroup: getpgid(pid) == pid ? pid : nil
        )

        let inputHandle = inputPipe.fileHandleForWriting
        let outputHandle = outputPipe.fileHandleForReading
        outputHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task {
                if data.isEmpty {
                    await self?.failConnection(generation: generation, with: CuaDriverError.processExited)
                } else {
                    await self?.receive(data: data, generation: generation)
                }
            }
        }
        readBuffers[generation] = Data()
        connection = CuaConnectionState(
            generation: generation,
            process: process,
            inputHandle: inputHandle,
            outputHandle: outputHandle,
            initializationTask: nil
        )

        let initializationTask = Task { [weak self] () throws -> Void in
            guard let self else { throw CuaDriverError.processExited }
            do {
                _ = try await self.sendRequest(
                    method: "initialize",
                    parameters: [
                        "protocolVersion": "2025-06-18",
                        "capabilities": [:],
                        "clientInfo": ["name": "Perry", "version": "1.0"],
                    ],
                    generation: generation
                )
                try await self.sendNotification(method: "notifications/initialized", generation: generation)
                await self.markConnectionReady(generation: generation)
            } catch {
                await self.failConnection(generation: generation, with: error)
                throw error
            }
        }
        connection?.initializationTask = initializationTask

        try await initializationTask.value
    }

    private func markConnectionReady(generation: UInt64) {
        guard connection?.generation == generation else { return }
        connection?.initializationTask = nil
    }

    static func embeddedEnvironment(configuration: CuaDriverConfiguration) -> [String: String] {
        var environment: [String: String] = [
            "CUA_DRIVER_EMBEDDED": "1",
            "CUA_DRIVER_HOST_BUNDLE_ID": configuration.hostBundleID,
            "CUA_DRIVER_PERMISSION_MODE": "bounded",
            "CUA_DRIVER_CAPABILITY_MANIFEST_FILE": configuration.capabilityManifestURL.path,
            "CUA_DRIVER_CAPABILITY_MANIFEST_APPROVED": "1",
            "CUA_DRIVER_RS_UPDATE_CHECK": "0",
            "CUA_DRIVER_RS_TELEMETRY_ENABLED": "0",
        ]
        let inherited = ProcessInfo.processInfo.environment
        for key in ["HOME", "TMPDIR", "LANG", "LC_ALL"] {
            if let value = inherited[key] {
                environment[key] = value
            }
        }
        return environment
    }

    private func listWindows(generation: UInt64, sessionID: String) async throws -> [CuaWindowTarget] {
        let result = try await callTool(
            name: "list_windows",
            arguments: ["on_screen_only": false],
            generation: generation
        )
        guard let rawWindows = result.structuredValue?["windows"] as? [[String: Any]] else {
            throw CuaDriverError.protocolFailure("list_windows returned no window list")
        }
        return rawWindows.compactMap { raw in
            guard let pid = integer(raw["pid"]),
                  let windowID = integer64(raw["window_id"]),
                  let title = raw["title"] as? String,
                  let bounds = raw["bounds"] as? [String: Any],
                  let x = double(bounds["x"]),
                  let y = double(bounds["y"]),
                  let width = double(bounds["width"]),
                  let height = double(bounds["height"]) else { return nil }
            let processID = Int32(pid)
            let bundleID = (raw["bundle_id"] as? String)
                ?? NSRunningApplication(processIdentifier: processID)?.bundleIdentifier
            guard let bundleID, !bundleID.isEmpty else { return nil }
            return CuaWindowTarget(
                bundleID: bundleID,
                processID: processID,
                windowID: windowID,
                connectionGeneration: generation,
                sessionID: sessionID,
                title: title,
                x: x,
                y: y,
                width: width,
                height: height,
                zIndex: integer(raw["z_index"]),
                isOnScreen: raw["is_on_screen"] as? Bool ?? true,
                isOnCurrentSpace: raw["on_current_space"] as? Bool ?? true
            )
        }
    }

    private func selectTarget(from windows: [CuaWindowTarget], hint: CuaTargetHint?) -> CuaWindowTarget? {
        guard let configuration = resolvedConfiguration() else { return nil }
        let scopedWindows = windows.filter { window in
            guard window.bundleID.caseInsensitiveCompare(configuration.hostBundleID) != .orderedSame else { return false }
            if let bundleID = hint?.bundleID,
               window.bundleID.caseInsensitiveCompare(bundleID) != .orderedSame {
                return false
            }
            guard let processID = hint?.processID else { return true }
            return Int32(processID) == window.processID
        }
        if let windowID = hint?.windowID {
            return scopedWindows.first { $0.windowID == windowID }
        }
        let windowTitle = hint?.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasTitle = !(windowTitle?.isEmpty ?? true)
        // The ≥80×60 floor only applies to unnamed discovery: a window the
        // session already named (by id or title) stays resolvable even when
        // it has legitimately shrunk below palette size mid-guide.
        let usableWindows = hasTitle
            ? scopedWindows
            : scopedWindows.filter { $0.width > 80 && $0.height > 60 }
        let visibleWindows = usableWindows.filter { $0.isOnScreen && $0.isOnCurrentSpace }
        let candidates = visibleWindows.isEmpty ? usableWindows : visibleWindows
        if hasTitle {
            return candidates.first { $0.title.caseInsensitiveCompare(windowTitle ?? "") == .orderedSame }
        }
        return candidates.max { left, right in
            if let leftZ = left.zIndex, let rightZ = right.zIndex, leftZ != rightZ {
                return leftZ < rightZ
            }
            return left.width * left.height < right.width * right.height
        }
    }

    private func actionArguments(
        for target: ComputerTarget?,
        state: CuaSessionState,
        sessionID: String,
        requiresTarget: Bool = true
    ) async throws -> [String: Any] {
        if let token = try await resolveElementToken(for: target, state: state, sessionID: sessionID) {
            return [
                "element_token": token,
                "pid": Int(state.target.processID),
                "window_id": state.target.windowID,
                "session": sessionID,
                "delivery_mode": "background",
            ]
        }
        guard let coordinates = target?.coordinates else {
            guard !requiresTarget else {
                throw CuaDriverError.targetNotFound
            }
            return [
                "pid": Int(state.target.processID),
                "window_id": state.target.windowID,
                "session": sessionID,
                "delivery_mode": "background",
            ]
        }
        return [
            "x": coordinates.x,
            "y": coordinates.y,
            "pid": Int(state.target.processID),
            "window_id": state.target.windowID,
            "session": sessionID,
            "delivery_mode": "background",
        ]
    }

    private func ensureTargetAllowed(_ target: CuaWindowTarget) throws {
        let context = WindowContext(appBundleID: target.bundleID, title: target.title)
        guard !TrustGuard().isWindowBlocked(context) else {
            throw CuaDriverError.protectedTarget
        }
    }

    private func validateResolvedTarget(_ target: CuaWindowTarget, sessionID: String) throws -> UInt64 {
        guard target.sessionID == sessionID else {
            throw CuaDriverError.targetSessionMismatch
        }
        let generation = target.connectionGeneration
        guard connection?.generation == generation,
              startedSessions[sessionID] == generation else {
            throw CuaDriverError.processExited
        }
        try ensureTargetAllowed(target)
        return generation
    }

    private func refreshSessionTarget(_ sessionID: String) async throws -> CuaSessionState {
        guard let previous = sessionStates[sessionID] else {
            throw CuaDriverError.targetNotFound
        }
        let currentTarget = try await refreshResolvedTarget(previous.target, sessionID: sessionID)
        let refreshed = CuaSessionState(
            generation: previous.generation,
            target: currentTarget,
            snapshotID: previous.snapshotID,
            elementLabels: previous.elementLabels
        )
        sessionStates[sessionID] = refreshed
        return refreshed
    }

    private func refreshResolvedTarget(_ target: CuaWindowTarget, sessionID: String) async throws -> CuaWindowTarget {
        let generation = try validateResolvedTarget(target, sessionID: sessionID)
        let currentTarget = try await listWindows(generation: generation, sessionID: sessionID).first { window in
            window.processID == target.processID && window.windowID == target.windowID
        }
        guard let currentTarget else {
            throw CuaDriverError.targetNotFound
        }
        try ensureTargetAllowed(currentTarget)
        return currentTarget
    }

    private func performAction(
        name: String,
        target: ComputerTarget?,
        state: CuaSessionState,
        sessionID: String,
        requiresTarget: Bool = true,
        additionalArguments: [String: Any] = [:]
    ) async throws -> CuaToolResult {
        var arguments = try await actionArguments(
            for: target,
            state: state,
            sessionID: sessionID,
            requiresTarget: requiresTarget
        )
        additionalArguments.forEach { arguments[$0.key] = $0.value }
        do {
            return try await callTool(name: name, arguments: arguments)
        } catch let error as CuaDriverError where error.isStaleTarget {
            guard target?.hasFreshSelector == true else {
                throw error
            }
            var refreshedArguments = try await actionArguments(
                for: target,
                state: state,
                sessionID: sessionID,
                requiresTarget: requiresTarget
            )
            additionalArguments.forEach { refreshedArguments[$0.key] = $0.value }
            return try await callTool(name: name, arguments: refreshedArguments)
        }
    }

    private func resolveElementToken(
        for target: ComputerTarget?,
        state: CuaSessionState,
        sessionID: String
    ) async throws -> String? {
        let stableID = target?.stableID
        let targetLabel = target?.label
        if let targetLabel, !targetLabel.isEmpty {
            return try await queryElementToken(label: targetLabel, state: state, sessionID: sessionID)
        }
        if let stableID {
            if let label = state.elementLabels[stableID] {
                return try await queryElementToken(label: label, state: state, sessionID: sessionID)
            }
            let token = stableID.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            if token.hasPrefix("s"), !token.isEmpty {
                return token
            }
            throw CuaDriverError.targetNotFound
        }
        return nil
    }

    private func queryElementToken(
        label targetLabel: String,
        state: CuaSessionState,
        sessionID: String
    ) async throws -> String {
        let result = try await callTool(
            name: "get_window_state",
            arguments: [
                "pid": Int(state.target.processID),
                "window_id": state.target.windowID,
                "include_screenshot": false,
                "query": targetLabel,
                "max_elements": 300,
                "max_depth": 12,
                "session": sessionID,
            ]
        )
        guard let elements = result.structuredValue?["elements"] as? [[String: Any]] else {
            throw CuaDriverError.targetNotFound
        }
        let match = elements.first { element in
            guard let label = element["label"] as? String else { return false }
            return label.caseInsensitiveCompare(targetLabel) == .orderedSame
                || label.localizedCaseInsensitiveContains(targetLabel)
        }
        guard let token = match?["element_token"] as? String else {
            throw CuaDriverError.targetNotFound
        }
        let currentState = sessionStates[sessionID]
        sessionStates[sessionID] = CuaSessionState(
            generation: state.generation,
            target: state.target,
            snapshotID: result.structuredValue?["snapshot_id"] as? String ?? currentState?.snapshotID,
            elementLabels: (currentState?.elementLabels ?? [:]).merging(elementLabels(from: result.structuredValue)) { _, newer in newer }
        )
        return token
    }

    private func callTool(
        name: String,
        arguments: [String: Any],
        generation explicitGeneration: UInt64? = nil
    ) async throws -> CuaToolResult {
        let sessionGeneration = (arguments["session"] as? String).flatMap { startedSessions[$0] }
        let generation = explicitGeneration ?? sessionGeneration
        if arguments["session"] != nil, generation == nil {
            throw CuaDriverError.processExited
        }
        let resultData = try await sendRequest(
            method: "tools/call",
            parameters: ["name": name, "arguments": arguments],
            generation: generation
        )
        guard let result = try JSONSerialization.jsonObject(with: resultData) as? [String: Any] else {
            throw CuaDriverError.protocolFailure("tool \(name) returned invalid JSON")
        }
        let structured = result["structuredContent"] as? [String: Any]
        let content = result["content"] as? [[String: Any]] ?? []
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        let images = content.compactMap { item -> Data? in
            guard item["type"] as? String == "image",
                  let encoded = item["data"] as? String else { return nil }
            return Data(base64Encoded: encoded)
        }
        let imageMIMEType = content.compactMap { item -> String? in
            guard item["type"] as? String == "image" else { return nil }
            return item["mimeType"] as? String
        }.first
        let toolResult = CuaToolResult(
            structuredData: structured.flatMap { try? JSONSerialization.data(withJSONObject: $0) },
            text: text,
            images: images,
            imageMIMEType: imageMIMEType,
            isError: result["isError"] as? Bool ?? false
        )
        if toolResult.isError {
            throw CuaDriverError.toolRejected(text)
        }
        return toolResult
    }

    private func sendRequest(
        method: String,
        parameters: [String: Any],
        generation expectedGeneration: UInt64? = nil
    ) async throws -> Data {
        try Task.checkCancellation()
        guard !retired else { throw CuaDriverError.processExited }
        guard let connection else { throw CuaDriverError.processExited }
        if let expectedGeneration, connection.generation != expectedGeneration {
            throw CuaDriverError.processExited
        }
        let generation = connection.generation
        let requestID = nextRequestID
        nextRequestID += 1
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestID,
            "method": method,
            "params": parameters,
        ]
        let requestData = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]) + Data([0x0A])
        let inputHandle = connection.inputHandle
        let timeout = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(Self.requestTimeout * 1_000_000_000))
            } catch {
                return
            }
            await self?.expire(requestID: requestID, generation: generation)
        }
        defer { timeout.cancel() }
        let response: Data = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending[requestID] = CuaPendingRequest(generation: generation, continuation: continuation)
                do {
                    try inputHandle.write(contentsOf: requestData)
                } catch {
                    pending.removeValue(forKey: requestID)
                    continuation.resume(throwing: CuaDriverError.processExited)
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(requestID: requestID, generation: generation) }
        }
        try Task.checkCancellation()
        return response
    }

    private func cancelRequest(requestID: Int, generation: UInt64) {
        guard let request = pending[requestID], request.generation == generation else { return }
        pending.removeValue(forKey: requestID)
        request.continuation.resume(throwing: CancellationError())
    }

    private func expire(requestID: Int, generation: UInt64) {
        guard connection?.generation == generation,
              let request = pending[requestID],
              request.generation == generation else { return }
        pending.removeValue(forKey: requestID)
        let error = CuaDriverError.protocolFailure("request timed out")
        request.continuation.resume(throwing: error)
        if !allowsRestart {
            failConnection(generation: generation, with: error)
        }
    }

    private func sendNotification(method: String, generation: UInt64) throws {
        guard let connection, connection.generation == generation else {
            throw CuaDriverError.processExited
        }
        let notification: [String: Any] = ["jsonrpc": "2.0", "method": method]
        let data = try JSONSerialization.data(withJSONObject: notification, options: [.sortedKeys]) + Data([0x0A])
        try connection.inputHandle.write(contentsOf: data)
    }

    private func receive(line: String, generation: UInt64) {
        guard connection?.generation == generation,
              let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let requestID = integer(message["id"]),
              let request = pending[requestID],
              request.generation == generation else {
            return
        }
        pending.removeValue(forKey: requestID)
        if let error = message["error"] as? [String: Any] {
            request.continuation.resume(throwing: CuaDriverError.protocolFailure(error["message"] as? String ?? "unknown JSON-RPC error"))
            return
        }
        guard let result = message["result"] as? [String: Any],
              let resultData = try? JSONSerialization.data(withJSONObject: result) else {
            request.continuation.resume(throwing: CuaDriverError.protocolFailure("response had no result"))
            return
        }
        request.continuation.resume(returning: resultData)
    }

    private func receive(data: Data, generation: UInt64) {
        guard connection?.generation == generation else { return }
        var buffer = readBuffers[generation, default: Data()]
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if let line = String(data: lineData, encoding: .utf8) {
                receive(line: line, generation: generation)
            }
        }
        readBuffers[generation] = buffer
    }

    private func failConnection(generation: UInt64, with error: Error) {
        guard connection?.generation == generation else { return }
        let waiting = pending.compactMap { _, request in
            request.generation == generation ? request.continuation : nil
        }
        pending = pending.filter { $0.value.generation != generation }
        readBuffers.removeValue(forKey: generation)
        tearDownProcess(terminate: true)
        startedSessions.removeAll()
        sessionStates.removeAll()
        for continuation in waiting {
            continuation.resume(throwing: error)
        }
    }

    private func tearDownProcess(terminate: Bool) {
        guard let connection else { return }
        self.connection = nil
        connection.outputHandle.readabilityHandler = nil
        connection.initializationTask?.cancel()
        connection.inputHandle.closeFile()
        connection.outputHandle.closeFile()
        if terminate, connection.process.isRunning {
            connection.process.terminate()
        }
    }

    private func finishRetirement() async throws {
        let started = ContinuousClock.now
        let waiting = pending.values.map(\.continuation)
        pending.removeAll()
        tearDownProcess(terminate: false)
        readBuffers.removeAll()
        startedSessions.removeAll()
        sessionStates.removeAll()
        for continuation in waiting {
            continuation.resume(throwing: CancellationError())
        }
        for owned in ownedProcesses.values where !owned.hasExited {
            try owned.signal(SIGTERM)
        }
        if try await waitForTermination(until: started.advanced(by: .milliseconds(200))) {
            return
        }
        for owned in ownedProcesses.values where !owned.hasExited {
            try owned.signal(SIGKILL)
        }
        guard try await waitForTermination(until: started.advanced(by: .milliseconds(490))) else {
            throw CuaDriverError.terminationUnconfirmed
        }
    }

    private func waitForTermination(until deadline: ContinuousClock.Instant) async throws -> Bool {
        while true {
            reapExitedProcesses()
            if ownedProcesses.isEmpty { return true }
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(until: min(deadline, ContinuousClock.now.advanced(by: .milliseconds(5))), clock: .continuous)
        }
    }

    private func reapExitedProcesses() {
        ownedProcesses = ownedProcesses.filter { !$0.value.hasExited }
    }

    private func formattedAccessibilitySnapshot(from value: [String: Any]?) -> String? {
        guard let elements = value?["elements"] as? [[String: Any]], !elements.isEmpty else { return nil }
        let lines = elements.compactMap { element -> String? in
            guard let rawRole = element["role"] as? String,
                  let label = element["label"] as? String else { return nil }
            let role = shortRole(rawRole)
            let token = element["element_token"] as? String
                ?? element["element_index"].map { String(describing: $0) }
                ?? "target"
            return "[\(token)] \(role) \(label)"
        }
        let tree = (value?["tree_markdown"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let tree, !tree.isEmpty {
            guard !lines.isEmpty else { return tree }
            return "\(tree)\n\nAction tokens:\n\(lines.joined(separator: "\n"))"
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func guideSnapshot(from value: [String: Any]?, target: CuaWindowTarget) -> AXSnapshot? {
        guard let elements = value?["elements"] as? [[String: Any]] else { return nil }
        let mapped = elements.compactMap { element -> AXElement? in
            let stableID: String
            if let token = element["element_token"] as? String, !token.isEmpty {
                stableID = token
            } else if let index = integer(element["element_index"]) {
                stableID = "cua-index:\(index)"
            } else {
                return nil
            }
            guard let frame = element["frame"] as? [String: Any],
                  let x = double(frame["x"]),
                  let y = double(frame["y"]),
                  let width = double(frame["width"] ?? frame["w"]),
                  let height = double(frame["height"] ?? frame["h"]) else {
                return nil
            }
            let rawRole = element["role"] as? String ?? ""
            let role = axGuideRole(rawRole)
            let label = nonEmpty(element["label"] as? String)
            let sensitivity: AXSensitivity = rawRole == "AXSecureTextField" ? .secure : .unknown
            let value: String? = nil
            return AXElement(
                stableID: stableID,
                role: role,
                label: label,
                frame: AXElementFrame(x: x, y: y, width: width, height: height),
                isActionable: axGuideRoleIsActionable(role),
                value: value,
                rawRole: rawRole,
                subrole: nonEmpty(element["subrole"] as? String),
                sensitivity: sensitivity
            )
        }
        return AXSnapshot(appBundleID: target.bundleID, windowTitle: target.title, elements: mapped)
    }

    private func elementLabels(from value: [String: Any]?) -> [String: String] {
        guard let elements = value?["elements"] as? [[String: Any]] else { return [:] }
        return elements.reduce(into: [:]) { labels, element in
            guard let token = element["element_token"] as? String,
                  let label = element["label"] as? String,
                  !label.isEmpty else { return }
            labels[token] = label
        }
    }

    private func shortRole(_ rawRole: String) -> String {
        switch rawRole {
        case "AXButton": return "button"
        case "AXTextField": return "textField"
        case "AXCheckBox": return "checkBox"
        case "AXSlider": return "slider"
        case "AXMenuItem": return "menuItem"
        case "AXMenu": return "menu"
        case "AXStaticText": return "staticText"
        case "AXWindow": return "window"
        case "AXWebArea": return "webArea"
        default: return rawRole
        }
    }

}

private func nonEmpty(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private extension CuaToolResult {
    var structuredValue: [String: Any]? {
        guard let structuredData,
              let value = try? JSONSerialization.jsonObject(with: structuredData) as? [String: Any] else { return nil }
        return value
    }

}

private func integer(_ value: Any?) -> Int? {
    if let number = value as? NSNumber { return number.intValue }
    if let string = value as? String { return Int(string) }
    return nil
}

private func integer64(_ value: Any?) -> Int64? {
    if let number = value as? NSNumber { return number.int64Value }
    if let string = value as? String { return Int64(string) }
    return nil
}

private func double(_ value: Any?) -> Double? {
    if let number = value as? NSNumber, number.doubleValue.isFinite { return number.doubleValue }
    if let string = value as? String, let number = Double(string), number.isFinite { return number }
    return nil
}

extension AppController {
    func reloadCuaDriverConfiguration() {
        guard isIdle, !foreground.supervisorActive, !backgroundTasks.hasRunningTasks, !foreground.startIsInFlight else {
            sessionStatus = "Finish active computer-use tasks before changing the Cua driver."
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await workers.reloadConfiguration()
                sessionStatus = "Cua computer-use configuration applied."
            } catch {
                sessionStatus = "Cua computer-use configuration could not be applied: \(error.localizedDescription)"
            }
        }
    }
}
