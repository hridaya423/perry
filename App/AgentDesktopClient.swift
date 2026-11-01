import AppKit
import Foundation
import PerryBrain
import PerryCore
import PerryGuide
import PerryRuntimes

private struct AgentDesktopSessionState: Sendable {
    let generation: UInt64
    let target: ScreenWindowTarget
    var snapshotID: String?
    var elements: [String: AgentDesktopElement]
    let pixelScale: Double
}

private enum AgentDesktopConfigurationSource {
    case discover
    case resolved(AgentDesktopConfiguration?)
}

private enum ResolvedPointer {
    case ref(String)
    case point(ComputerCoordinates)
}

actor AgentDesktopClient {
    private static let readTimeout = Duration.seconds(6)
    private static let stepDelay = Duration.milliseconds(300)
    private static let foregroundOnlyBundleIDs: Set<String> = ["com.apple.finder"]
    private static let healthSession = "perry-health"
    private static let repeatableRoles: Set<String> = ["button", "link", "tab", "radiobutton", "menuitem", "row", "cell", "treeitem"]
    private static let consequentialWords: Set<String> = [
        "send", "delete", "remove", "pay", "buy", "purchase", "order", "checkout", "submit", "confirm", "post",
        "publish", "transfer", "erase", "trash", "quit", "reply", "forward", "share", "install", "uninstall",
        "allow", "approve", "accept", "decline", "reject", "download", "upload", "archive", "move", "empty",
        "discard", "cancel", "subscribe", "unsubscribe", "add", "new", "create", "duplicate", "book", "call",
        "sign", "log", "logout", "signout", "invite", "replace", "merge",
    ]
    private static let windowManagerBundleID = "com.apple.WindowManager"
    private static let stageOverlayTitle = "Gesture Blocking Overlay"
    static let windowInStageStrip = ScreenDriverError.toolRejected(
        "That window is in the Stage Manager strip. Click it to bring it to the front, then try again."
    )
    static let pointerNeedsForeground = ScreenDriverError.toolRejected(
        "Clicking a spot or dragging moves your cursor, so I only do it while I work in front of you."
    )

    private static let readCommands: Set<String> = ["permissions", "list-windows", "snapshot", "screenshot", "get"]

    private let requestTimeout: Duration
    private let allowsRestart: Bool
    private let allowsForegroundInput: Bool
    private let fallback: CuaDriverClient?
    private var configurationSource: AgentDesktopConfigurationSource
    private var generation: UInt64 = 0
    private var startedSessions: [String: UInt64] = [:]
    private var sessionStates: [String: AgentDesktopSessionState] = [:]
    private var sessionTargets: [String: ScreenWindowTarget] = [:]
    private var retired = false
    private var retirementTask: Task<Void, Error>?
    private var inFlight: [UUID: Task<JSONValue, Error>] = [:]
    private var healthHostStarted = false
    private var stagedWindowIDs: Set<Int64> = []

    init(allowsRestart: Bool = true, allowsForegroundInput: Bool = false, fallback: CuaDriverClient? = nil) {
        self.init(source: .discover, allowsRestart: allowsRestart, allowsForegroundInput: allowsForegroundInput, fallback: fallback)
    }

    init(
        configuration: AgentDesktopConfiguration?,
        allowsRestart: Bool = true,
        allowsForegroundInput: Bool = false,
        fallback: CuaDriverClient? = nil,
        requestTimeout: Duration = .seconds(15)
    ) {
        self.init(
            source: .resolved(configuration),
            allowsRestart: allowsRestart,
            allowsForegroundInput: allowsForegroundInput,
            fallback: fallback,
            requestTimeout: requestTimeout
        )
    }

    private init(
        source: AgentDesktopConfigurationSource,
        allowsRestart: Bool,
        allowsForegroundInput: Bool,
        fallback: CuaDriverClient?,
        requestTimeout: Duration = .seconds(15)
    ) {
        configurationSource = source
        self.allowsRestart = allowsRestart
        self.allowsForegroundInput = allowsForegroundInput
        self.fallback = fallback
        self.requestTimeout = requestTimeout
    }

    func health() async -> ScreenDriverHealth {
        guard resolvedConfiguration() != nil else {
            return ScreenDriverHealth(ready: false, summary: "Screen control isn’t available. Reinstall Perry.")
        }
        do {
            healthHostStarted = true
            let report = try await run(["permissions"], session: Self.healthSession, timeout: Self.readTimeout)
            guard report["accessibility"]?["state"]?.stringValue == "granted",
                  report["screen_recording"]?["state"]?.stringValue == "granted" else {
                return ScreenDriverHealth(
                    ready: false,
                    summary: "I need Accessibility and Screen Recording access. Turn both on for Perry in System Settings."
                )
            }
            return ScreenDriverHealth(ready: true, summary: "Screen control is ready.")
        } catch {
            return ScreenDriverHealth(ready: false, summary: "Screen control isn’t responding. Try again.")
        }
    }

    func target(for sessionID: String) -> ScreenWindowTarget? {
        guard let state = sessionStates[sessionID], state.generation == generation else { return nil }
        return state.target
    }

    func capture(target hint: ScreenTargetHint?, sessionID: String) async throws -> ScreenCapturedWindow {
        let resolvedTarget = try await resolveTarget(hint, sessionID: sessionID)
        return try await capture(resolvedTarget: resolvedTarget, sessionID: sessionID)
    }

    func resolveTarget(_ hint: ScreenTargetHint?, sessionID: String) async throws -> ScreenWindowTarget {
        try await surfacingFailures { try await resolveTargetReportingDelivery(hint, sessionID: sessionID) }
    }

    func capture(resolvedTarget: ScreenWindowTarget, sessionID: String, includeScreenshot: Bool = true) async throws -> ScreenCapturedWindow {
        try await surfacingFailures {
            try await captureReportingDelivery(resolvedTarget: resolvedTarget, sessionID: sessionID, includeScreenshot: includeScreenshot)
        }
    }

    func execute(_ action: ComputerAction, sessionID: String) async throws -> StepResult {
        try await surfacingFailures { try await executeReportingDelivery(action, sessionID: sessionID) }
    }

    func insertText(_ text: String, target hint: ScreenTargetHint, sessionID: String) async throws -> ScreenWindowTarget {
        guard !text.isEmpty else {
            throw ScreenDriverError.toolRejected("Text insertion requires non-empty text.")
        }
        let resolvedTarget = try await resolveTarget(hint, sessionID: sessionID)
        return try await insertText(text, resolvedTarget: resolvedTarget, sessionID: sessionID)
    }

    func insertText(_ text: String, resolvedTarget: ScreenWindowTarget, sessionID: String) async throws -> ScreenWindowTarget {
        guard !text.isEmpty else {
            throw ScreenDriverError.toolRejected("Text insertion requires non-empty text.")
        }
        return try await surfacingFailures {
            try await insertTextReportingDelivery(text, resolvedTarget: resolvedTarget, sessionID: sessionID)
        }
    }

    private func surfacingFailures<Value>(_ body: () async throws -> Value) async throws -> Value {
        do {
            return try await body()
        } catch let failure as AgentDesktopFailure {
            throw failure.error
        }
    }

    private func resolveTargetReportingDelivery(_ hint: ScreenTargetHint?, sessionID: String) async throws -> ScreenWindowTarget {
        sessionStates[sessionID] = nil
        sessionTargets[sessionID] = nil
        let generation = try ensureSession(sessionID)
        let windows = try await listWindows(generation: generation, sessionID: sessionID)
        guard var target = selectTarget(from: windows, hint: hint) else {
            throw ScreenDriverError.noTargetWindow
        }
        try ensureTargetAllowed(target)
        if stagedWindowIDs.contains(target.windowID), allowsForegroundInput {
            target = try await bringForward(target, generation: generation, sessionID: sessionID)
        }
        guard self.generation == generation, startedSessions[sessionID] == generation else {
            throw ScreenDriverError.processExited
        }
        sessionTargets[sessionID] = target
        return target
    }

    private func captureReportingDelivery(
        resolvedTarget: ScreenWindowTarget,
        sessionID: String,
        includeScreenshot: Bool
    ) async throws -> ScreenCapturedWindow {
        try Task.checkCancellation()
        let generation = try validateResolvedTarget(resolvedTarget, sessionID: sessionID)
        let staged = stagedWindowIDs.contains(resolvedTarget.windowID)
        if staged, includeScreenshot {
            throw Self.windowInStageStrip
        }
        let window = AgentDesktopWindow.identifier(resolvedTarget.windowID)
        async let tree = run(
            ["snapshot", "--window-id", window, "--include-bounds", "--max-depth", "12", "--timeout-ms", "3000"],
            session: sessionID,
            timeout: Self.readTimeout
        )
        async let image: JSONValue? = includeScreenshot
            ? run(["screenshot", "--window-id", window], session: sessionID, timeout: Self.readTimeout)
            : nil
        let (treeData, imageData) = try await (tree, image)
        let rawScreenshot = imageData?["data"]?.stringValue.flatMap { Data(base64Encoded: $0) } ?? Data()
        if includeScreenshot, rawScreenshot.isEmpty {
            throw ScreenDriverError.noScreenshot
        }
        let backingScale = imageData?["scale_factor"]?.doubleValue
            ?? sessionStates[sessionID]?.pixelScale
            ?? AgentDesktopWindow.displayScale(for: resolvedTarget)
        let screenshotData = rawScreenshot.isEmpty ? rawScreenshot : AgentDesktopScreenshot.croppedToWindow(
            rawScreenshot,
            width: resolvedTarget.width,
            height: resolvedTarget.height,
            scale: backingScale
        )
        guard self.generation == generation, startedSessions[sessionID] == generation else {
            throw ScreenDriverError.processExited
        }
        guard let snapshot = AgentDesktopSnapshot(treeData) else {
            throw ScreenDriverError.protocolFailure("snapshot returned no tree")
        }
        sessionStates[sessionID] = AgentDesktopSessionState(
            generation: generation,
            target: resolvedTarget,
            snapshotID: snapshot.snapshotID,
            elements: snapshot.elements(in: staged ? Self.placed(resolvedTarget, at: snapshot.windowFrame) : resolvedTarget, scale: backingScale),
            pixelScale: backingScale
        )
        sessionTargets[sessionID] = resolvedTarget
        return ScreenCapturedWindow(
            target: resolvedTarget,
            screenshotData: screenshotData,
            screenshotMIMEType: "image/png",
            accessibilitySnapshot: snapshot.actionTokens,
            accessibilitySnapshotModel: snapshot.guideSnapshot(target: resolvedTarget),
            snapshotID: snapshot.snapshotID,
            elementDetails: snapshot.details,
            treeComplete: snapshot.complete
        )
    }

    private func executeReportingDelivery(_ action: ComputerAction, sessionID: String) async throws -> StepResult {
        try Task.checkCancellation()
        _ = try ensureSession(sessionID)
        let state = try await refreshSessionTarget(sessionID)
        if let expected = action.expectedWindow {
            let target = state.target
            guard target.processID == expected.processID,
                  target.windowID == Int64(expected.windowID),
                  target.bundleID.lowercased() == expected.bundleID.lowercased() else {
                throw ScreenDriverError.targetMismatch
            }
        }
        if case .steps(let operations) = action.operation {
            for (index, operation) in operations.enumerated() {
                if index > 0 { try await Task.sleep(for: Self.stepDelay) }
                try await perform(operation, state: state, sessionID: sessionID)
            }
        } else {
            try await perform(action.operation, state: state, sessionID: sessionID)
        }
        return StepResult(stepID: action.stepID, success: true, message: action.operation.defaultMessage)
    }

    private func insertTextReportingDelivery(_ text: String, resolvedTarget: ScreenWindowTarget, sessionID: String) async throws -> ScreenWindowTarget {
        try Task.checkCancellation()
        _ = try validateResolvedTarget(resolvedTarget, sessionID: sessionID)
        let field = try await focusedRef(in: resolvedTarget, sessionID: sessionID)
        let before = try await fieldValue(field, sessionID: sessionID)
        let typed = try await run(["type", field], payload: text, session: sessionID, timeout: requestTimeout)
        if Self.delivery(typed) != "delivered_verified" {
            let after = try await fieldValue(field, sessionID: sessionID)
            guard Self.occurrences(of: text, in: after) > Self.occurrences(of: text, in: before) else {
                throw ScreenDriverError.toolRejected("I couldn’t confirm the text went into the field.")
            }
        }
        let current = try await refreshResolvedTarget(resolvedTarget, sessionID: sessionID)
        guard current == resolvedTarget else {
            throw ScreenDriverError.toolRejected("The target window changed before text insertion could be verified.")
        }
        sessionStates[sessionID] = AgentDesktopSessionState(
            generation: current.connectionGeneration,
            target: current,
            snapshotID: nil,
            elements: [:],
            pixelScale: sessionStates[sessionID]?.pixelScale ?? AgentDesktopWindow.displayScale(for: current)
        )
        sessionTargets[sessionID] = current
        return current
    }

    func shutdown() async {
        let sessions = hostSessions()
        cancelInFlight()
        generation += 1
        forgetSessions()
        sessionTargets.removeAll()
        await terminateHosts(sessions)
        await fallback?.shutdown()
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

    func reloadConfiguration() async {
        guard !retired else { return }
        await shutdown()
        configurationSource = .discover
    }

    private func finishRetirement() async throws {
        let sessions = hostSessions()
        cancelInFlight()
        forgetSessions()
        sessionTargets.removeAll()
        await terminateHosts(sessions)
        try await fallback?.retire()
    }

    private func hostSessions() -> [String] {
        let sessions = Array(startedSessions.keys) + (healthHostStarted ? [Self.healthSession] : [])
        healthHostStarted = false
        return sessions
    }

    private func terminateHosts(_ sessions: [String]) async {
        guard let configuration = resolvedConfiguration(), !sessions.isEmpty else { return }
        await Task.detached {
            for session in sessions {
                AgentDesktopHosts.terminate(executableURL: configuration.executableURL, session: session)
            }
        }.value
    }

    private func resolvedConfiguration() -> AgentDesktopConfiguration? {
        switch configurationSource {
        case .discover:
            let configuration = AgentDesktopConfiguration.discover()
            configurationSource = .resolved(configuration)
            return configuration
        case .resolved(let configuration):
            return configuration
        }
    }

    private func ensureSession(_ sessionID: String) throws -> UInt64 {
        try Task.checkCancellation()
        guard canRun else { throw ScreenDriverError.processExited }
        guard resolvedConfiguration() != nil else { throw ScreenDriverError.unavailable }
        if startedSessions[sessionID] == generation { return generation }
        startedSessions[sessionID] = generation
        return generation
    }

    private var canRun: Bool {
        !retired && (allowsRestart || generation == 0)
    }

    private func run(_ arguments: [String], payload: String? = nil, session: String, timeout: Duration) async throws -> JSONValue {
        guard canRun else { throw ScreenDriverError.processExited }
        guard let configuration = resolvedConfiguration() else { throw ScreenDriverError.unavailable }
        let command = AgentDesktopCommand(executableURL: configuration.executableURL, environment: configuration.environment)
        let name = arguments.first ?? "call"
        PerfMark.markDynamic("agent-desktop.\(name).begin")
        defer { PerfMark.markDynamic("agent-desktop.\(name).end") }
        let id = UUID()
        let call = Task { try await command.run(arguments, payload: payload, session: session, timeout: timeout) }
        inFlight[id] = call
        defer { inFlight[id] = nil }
        do {
            return try await withTaskCancellationHandler {
                try await call.value
            } onCancel: {
                call.cancel()
            }
        } catch let failure as AgentDesktopFailure where failure.error.isRespawnableReadFailure {
            await failSessions()
            throw failure
        } catch is CancellationError where !Task.isCancelled {
            throw AgentDesktopFailure(error: .processExited, mayHaveLanded: true)
        } catch is CancellationError {
            if !Self.readCommands.contains(name) {
                sessionStates[session]?.snapshotID = nil
                sessionStates[session]?.elements = [:]
                await terminateHosts([session])
            }
            throw CancellationError()
        }
    }

    private func fieldValue(_ field: String, sessionID: String) async throws -> String {
        let readback = try await run(["get", field, "--property", "value"], session: sessionID, timeout: Self.readTimeout)
        return readback["value"]?.stringValue ?? ""
    }

    private static func delivery(_ result: JSONValue) -> String? {
        result["disposition"]?["delivery"]?.stringValue
    }

    private static func occurrences(of text: String, in value: String) -> Int {
        value.components(separatedBy: text).count - 1
    }

    private func cancelInFlight() {
        for call in inFlight.values {
            call.cancel()
        }
    }

    private func failSessions() async {
        let sessions = Array(startedSessions.keys)
        generation += 1
        forgetSessions()
        await terminateHosts(sessions)
    }

    private func forgetSessions() {
        startedSessions.removeAll()
        sessionStates.removeAll()
    }

    private func listWindows(generation: UInt64, sessionID: String) async throws -> [ScreenWindowTarget] {
        guard let configuration = resolvedConfiguration() else { throw ScreenDriverError.unavailable }
        let data = try await run(["list-windows"], session: sessionID, timeout: Self.readTimeout)
        let owned = AgentDesktopWindow.list(data).compactMap { window -> (window: AgentDesktopWindow, bundleID: String)? in
            guard let bundleID = configuration.bundleIdentifier(window.processID), !bundleID.isEmpty else { return nil }
            return (window, bundleID)
        }
        let stageOverlays = Set(owned.filter { entry in
            entry.bundleID == Self.windowManagerBundleID && entry.window.title == Self.stageOverlayTitle
                && entry.window.width > 0 && entry.window.height > 0
        }.map(\.window.frame))
        let apps = owned.filter { $0.bundleID != Self.windowManagerBundleID }
        stagedWindowIDs = Set(apps.filter { stageOverlays.contains($0.window.frame) }.map(\.window.windowID))
        return apps.map { window, bundleID in
            ScreenWindowTarget(
                bundleID: bundleID,
                processID: window.processID,
                windowID: window.windowID,
                connectionGeneration: generation,
                sessionID: sessionID,
                title: window.title,
                x: window.x,
                y: window.y,
                width: window.width,
                height: window.height,
                zIndex: window.isFocused ? 1 : 0,
                isOnScreen: window.isVisible,
                isOnCurrentSpace: true
            )
        }
    }

    private func bringForward(_ target: ScreenWindowTarget, generation: UInt64, sessionID: String) async throws -> ScreenWindowTarget {
        let arguments = ["focus-window", "--window-id", AgentDesktopWindow.identifier(target.windowID)]
        do {
            _ = try await run(arguments, session: sessionID, timeout: requestTimeout)
        } catch let failure as AgentDesktopFailure where failure.error == .unsupportedAction && !failure.mayHaveLanded {
            _ = try await run(arguments + ["--headed"], session: sessionID, timeout: requestTimeout)
        }
        for _ in 0..<8 {
            let current = try await liveWindow(matching: target, generation: generation, sessionID: sessionID)
            if !stagedWindowIDs.contains(current.windowID) { return current }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw Self.windowInStageStrip
    }

    private static func placed(_ target: ScreenWindowTarget, at frame: AXElementFrame?) -> ScreenWindowTarget {
        guard let frame else { return target }
        return ScreenWindowTarget(
            bundleID: target.bundleID,
            processID: target.processID,
            windowID: target.windowID,
            connectionGeneration: target.connectionGeneration,
            sessionID: target.sessionID,
            title: target.title,
            x: frame.x,
            y: frame.y,
            width: frame.width,
            height: frame.height,
            zIndex: target.zIndex,
            isOnScreen: target.isOnScreen,
            isOnCurrentSpace: target.isOnCurrentSpace
        )
    }

    private func selectTarget(from windows: [ScreenWindowTarget], hint: ScreenTargetHint?) -> ScreenWindowTarget? {
        guard let configuration = resolvedConfiguration() else { return nil }
        let scopedWindows = windows.filter { window in
            guard window.bundleID.caseInsensitiveCompare(configuration.hostBundleID) != .orderedSame else { return false }
            if let bundleID = hint?.bundleID,
               window.bundleID.caseInsensitiveCompare(bundleID) != .orderedSame {
                return false
            }
            guard let processID = hint?.processID else { return true }
            return processID == window.processID
        }
        if let windowID = hint?.windowID {
            return scopedWindows.first { $0.windowID == windowID }
        }
        let windowTitle = hint?.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasTitle = !(windowTitle?.isEmpty ?? true)
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

    private func ensureTargetAllowed(_ target: ScreenWindowTarget) throws {
        let context = WindowContext(appBundleID: target.bundleID, title: target.title)
        guard !TrustGuard().isWindowBlocked(context) else {
            throw ScreenDriverError.protectedTarget
        }
    }

    private func validateResolvedTarget(_ target: ScreenWindowTarget, sessionID: String) throws -> UInt64 {
        guard target.sessionID == sessionID else {
            throw ScreenDriverError.targetSessionMismatch
        }
        let generation = target.connectionGeneration
        guard !retired, self.generation == generation, startedSessions[sessionID] == generation else {
            throw ScreenDriverError.processExited
        }
        try ensureTargetAllowed(target)
        return generation
    }

    private func liveWindow(matching target: ScreenWindowTarget, generation: UInt64, sessionID: String) async throws -> ScreenWindowTarget {
        let current = try await listWindows(generation: generation, sessionID: sessionID)
            .first { $0.processID == target.processID && $0.windowID == target.windowID }
        guard let current else {
            throw ScreenDriverError.targetNotFound
        }
        try ensureTargetAllowed(current)
        return current
    }

    private func refreshResolvedTarget(_ target: ScreenWindowTarget, sessionID: String) async throws -> ScreenWindowTarget {
        let generation = try validateResolvedTarget(target, sessionID: sessionID)
        return try await liveWindow(matching: target, generation: generation, sessionID: sessionID)
    }

    private func refreshSessionTarget(_ sessionID: String) async throws -> AgentDesktopSessionState {
        if let previous = sessionStates[sessionID], previous.generation == generation {
            let currentTarget = try await refreshResolvedTarget(previous.target, sessionID: sessionID)
            let refreshed = AgentDesktopSessionState(
                generation: previous.generation,
                target: currentTarget,
                snapshotID: previous.snapshotID,
                elements: previous.elements,
                pixelScale: previous.pixelScale
            )
            sessionStates[sessionID] = refreshed
            sessionTargets[sessionID] = currentTarget
            return refreshed
        }
        guard let boundTarget = sessionTargets[sessionID], startedSessions[sessionID] == generation else {
            throw ScreenDriverError.targetNotFound
        }
        let currentTarget = try await liveWindow(matching: boundTarget, generation: generation, sessionID: sessionID)
        let state = AgentDesktopSessionState(
            generation: generation,
            target: currentTarget,
            snapshotID: nil,
            elements: [:],
            pixelScale: AgentDesktopWindow.displayScale(for: currentTarget)
        )
        sessionStates[sessionID] = state
        sessionTargets[sessionID] = currentTarget
        return state
    }

    private func headed(_ target: ScreenWindowTarget) -> [String] {
        allowsForegroundInput && Self.foregroundOnlyBundleIDs.contains(target.bundleID.lowercased()) ? ["--headed"] : []
    }

    private func perform(_ operation: ComputerAction.Operation, state: AgentDesktopSessionState, sessionID: String) async throws {
        do {
            try await dispatch(operation, state: state, sessionID: sessionID, trustsSnapshotToken: true)
        } catch let failure as AgentDesktopFailure where failure.error.isStaleTarget && !failure.mayHaveLanded {
            guard operation.target?.hasFreshSelector == true else { throw failure }
            try await dispatch(operation, state: state, sessionID: sessionID, trustsSnapshotToken: false)
        }
    }

    private func dispatch(
        _ operation: ComputerAction.Operation,
        state: AgentDesktopSessionState,
        sessionID: String,
        trustsSnapshotToken: Bool
    ) async throws {
        let window = AgentDesktopWindow.identifier(state.target.windowID)
        func pointer(_ target: ComputerTarget) async throws -> ResolvedPointer {
            try await self.pointer(target, state: state, sessionID: sessionID, trustsSnapshotToken: trustsSnapshotToken)
        }
        switch operation {
        case .click(let target):
            switch try await pointer(target) {
            case .ref(let ref): try await clickElement("click", ref: ref, target: target, button: "left", count: 1, state: state, sessionID: sessionID)
            case .point(let point): try await pointerClick(point, button: "left", count: 1, state: state, sessionID: sessionID)
            }
        case .rightClick(let target):
            switch try await pointer(target) {
            case .ref(let ref): try await clickElement("right-click", ref: ref, target: target, button: "right", count: 1, state: state, sessionID: sessionID)
            case .point(let point): try await pointerClick(point, button: "right", count: 1, state: state, sessionID: sessionID)
            }
        case .doubleClick(let target):
            switch try await pointer(target) {
            case .ref(let ref): try await clickElement("double-click", ref: ref, target: target, button: "left", count: 2, state: state, sessionID: sessionID)
            case .point(let point): try await pointerClick(point, button: "left", count: 2, state: state, sessionID: sessionID)
            }
        case .typeText(let text, let target):
            let field: String
            if let target {
                switch try await pointer(target) {
                case .ref(let ref):
                    field = ref
                case .point(let point):
                    try await pointerClick(point, button: "left", count: 1, state: state, sessionID: sessionID)
                    field = try await focusedRef(in: state.target, sessionID: sessionID)
                }
            } else {
                field = try await focusedRef(in: state.target, sessionID: sessionID)
            }
            try await refAction(["type", field], payload: text, state: state, sessionID: sessionID)
        case .setValue(let value, let target):
            guard let ref = try await elementRef(for: target, state: state, sessionID: sessionID, trustsSnapshotToken: trustsSnapshotToken) else {
                throw ScreenDriverError.targetNotFound
            }
            _ = try await run(["set-value", ref], payload: value, session: sessionID, timeout: requestTimeout)
        case .scroll(let direction, let amount, let by, let target):
            let ref: String
            if let target, let resolved = try await elementRef(for: target, state: state, sessionID: sessionID, trustsSnapshotToken: trustsSnapshotToken) {
                ref = resolved
            } else {
                ref = try await scrollableRef(in: state.target, sessionID: sessionID)
            }
            let units = by == .page ? amount * 10 : amount
            try await refAction(
                ["scroll", ref, "--direction", direction.rawValue, "--amount", String(max(1, units))],
                state: state,
                sessionID: sessionID
            )
        case .pressKey(let key, let modifiers, let target):
            try await focus(target, state: state, sessionID: sessionID, trustsSnapshotToken: trustsSnapshotToken)
            let combo = ((modifiers ?? []) + [key]).map { $0.lowercased() }.joined(separator: "+")
            _ = try await run(["press", combo, "--window-id", window] + headed(state.target), session: sessionID, timeout: requestTimeout)
        case .hotkey(let keys, let target):
            try await focus(target, state: state, sessionID: sessionID, trustsSnapshotToken: trustsSnapshotToken)
            let combo = keys.map { $0.lowercased() }.joined(separator: "+")
            _ = try await run(["press", combo, "--window-id", window] + headed(state.target), session: sessionID, timeout: requestTimeout)
        case .drag(let from, let to, let durationMilliseconds, let steps):
            guard !stagedWindowIDs.contains(state.target.windowID) else { throw Self.windowInStageStrip }
            if fallback != nil {
                let drag = ComputerAction(stepID: "drag", operation: .drag(from: from, to: to, durationMilliseconds: durationMilliseconds, steps: steps))
                try await viaFallback(drag, state: state, sessionID: sessionID)
                return
            }
            guard allowsForegroundInput else { throw Self.pointerNeedsForeground }
            let start = screenPoint(from, state: state)
            let end = screenPoint(to, state: state)
            var arguments = ["drag", "--from-xy=\(Self.coordinate(start))", "--to-xy=\(Self.coordinate(end))", "--headed"]
            if let durationMilliseconds { arguments += ["--duration", String(durationMilliseconds)] }
            _ = try await run(arguments, session: sessionID, timeout: requestTimeout)
        case .steps:
            throw ScreenDriverError.unsupportedAction
        }
    }

    private func refAction(
        _ arguments: [String],
        payload: String? = nil,
        state: AgentDesktopSessionState,
        sessionID: String
    ) async throws {
        let headed = headed(state.target)
        do {
            _ = try await run(arguments + headed, payload: payload, session: sessionID, timeout: requestTimeout)
        } catch let failure as AgentDesktopFailure
            where failure.error == .unsupportedAction && !failure.mayHaveLanded && allowsForegroundInput && headed.isEmpty {
            _ = try await run(arguments + ["--headed"], payload: payload, session: sessionID, timeout: requestTimeout)
        }
    }

    private func pointerClick(
        _ point: ComputerCoordinates,
        button: String,
        count: Int,
        state: AgentDesktopSessionState,
        sessionID: String
    ) async throws {
        guard !stagedWindowIDs.contains(state.target.windowID) else { throw Self.windowInStageStrip }
        if fallback != nil {
            try await viaFallback(Self.pointerAction(point, button: button, count: count), state: state, sessionID: sessionID)
            return
        }
        guard allowsForegroundInput else { throw Self.pointerNeedsForeground }
        let screen = screenPoint(point, state: state)
        _ = try await run(
            ["mouse-click", "--xy=\(Self.coordinate(screen))", "--button", button, "--count", String(count), "--headed"],
            session: sessionID,
            timeout: requestTimeout
        )
    }

    private func clickElement(
        _ command: String,
        ref: String,
        target: ComputerTarget,
        button: String,
        count: Int,
        state: AgentDesktopSessionState,
        sessionID: String
    ) async throws {
        let element = sessionStates[sessionID]?.elements[ref] ?? state.elements[ref]
        guard fallback != nil, !stagedWindowIDs.contains(state.target.windowID), let point = target.point ?? element?.center else {
            try await refAction([command, ref], state: state, sessionID: sessionID)
            return
        }
        let result: JSONValue
        do {
            result = try await run([command, ref] + headed(state.target), session: sessionID, timeout: requestTimeout)
        } catch let failure as AgentDesktopFailure where !failure.mayHaveLanded && Self.physicalClickCanSubstitute(for: failure.error) {
            try await viaFallback(Self.pointerAction(point, button: button, count: count), state: state, sessionID: sessionID)
            return
        }
        guard command == "click", Self.landedWithoutEffect(result), Self.canRepeatClick(on: element, label: target.label) else {
            return
        }
        PerfMark.mark("agent-desktop.click.unverified")
        try await viaFallback(Self.pointerAction(point, button: button, count: count), state: state, sessionID: sessionID)
    }

    private func viaFallback(_ action: ComputerAction, state: AgentDesktopSessionState, sessionID: String) async throws {
        guard let fallback else { throw Self.pointerNeedsForeground }
        guard !stagedWindowIDs.contains(state.target.windowID) else { throw Self.windowInStageStrip }
        let window = state.target
        _ = try await fallback.resolveTarget(
            ScreenTargetHint(bundleID: window.bundleID, processID: window.processID, windowID: window.windowID),
            sessionID: sessionID
        )
        _ = try await fallback.execute(action, sessionID: sessionID)
    }

    private static func pointerAction(_ point: ComputerCoordinates, button: String, count: Int) -> ComputerAction {
        let target = ComputerTarget.point(point)
        let operation: ComputerAction.Operation = count == 2 ? .doubleClick(target) : button == "right" ? .rightClick(target) : .click(target)
        return ComputerAction(stepID: "fallback-pointer", operation: operation)
    }

    private static func physicalClickCanSubstitute(for error: ScreenDriverError) -> Bool {
        switch error {
        case .unsupportedAction, .toolRejected: return true
        default: return false
        }
    }

    static func landedWithoutEffect(_ result: JSONValue) -> Bool {
        delivery(result) == "delivered_unverified" && (result["surfaces"]?.arrayValue ?? []).isEmpty
    }

    static func canRepeatClick(on element: AgentDesktopElement?, label: String?) -> Bool {
        guard let element, repeatableRoles.contains(element.role), !element.holdsState,
              let label = AgentDesktopSnapshot.nonEmpty(label ?? element.label) else { return false }
        let words = label.lowercased().split { !$0.isLetter }.map(String.init)
        return !words.isEmpty && words.allSatisfy { !consequentialWords.contains($0) }
    }

    private func screenPoint(_ point: ComputerCoordinates, state: AgentDesktopSessionState) -> ComputerCoordinates {
        let scale = state.pixelScale > 0 ? state.pixelScale : 1
        return ComputerCoordinates(x: state.target.x + point.x / scale, y: state.target.y + point.y / scale)
    }

    private static func coordinate(_ point: ComputerCoordinates) -> String {
        "\(Int(point.x.rounded())),\(Int(point.y.rounded()))"
    }

    private func focus(
        _ target: ComputerTarget?,
        state: AgentDesktopSessionState,
        sessionID: String,
        trustsSnapshotToken: Bool
    ) async throws {
        guard let target, let ref = try await elementRef(for: target, state: state, sessionID: sessionID, trustsSnapshotToken: trustsSnapshotToken) else {
            return
        }
        _ = try await run(["focus", ref], session: sessionID, timeout: requestTimeout)
    }

    private func pointer(
        _ target: ComputerTarget,
        state: AgentDesktopSessionState,
        sessionID: String,
        trustsSnapshotToken: Bool
    ) async throws -> ResolvedPointer {
        do {
            if let ref = try await elementRef(for: target, state: state, sessionID: sessionID, trustsSnapshotToken: trustsSnapshotToken) {
                return .ref(ref)
            }
        } catch ScreenDriverError.targetNotFound where target.point != nil {
        }
        guard let point = target.point else { throw ScreenDriverError.targetNotFound }
        return .point(point)
    }

    private func elementRef(
        for target: ComputerTarget,
        state: AgentDesktopSessionState,
        sessionID: String,
        trustsSnapshotToken: Bool
    ) async throws -> String? {
        guard target.hasFreshSelector else { return nil }
        if trustsSnapshotToken, let id = target.id, let snapshotID = state.snapshotID, id.hasPrefix("@\(snapshotID):") {
            return id
        }
        if let label = target.label, !label.isEmpty {
            return try await queryRef(label: label, state: state, sessionID: sessionID)
        }
        guard let id = target.id else { return nil }
        if let label = state.elements[id]?.label {
            return try await queryRef(label: label, state: state, sessionID: sessionID)
        }
        guard id.hasPrefix("@") else {
            throw ScreenDriverError.targetNotFound
        }
        return id
    }

    private func liveSnapshot(_ target: ScreenWindowTarget, sessionID: String, arguments: [String] = []) async throws -> AgentDesktopSnapshot {
        let data = try await run(
            ["snapshot", "--window-id", AgentDesktopWindow.identifier(target.windowID), "--max-depth", "12"] + arguments,
            session: sessionID,
            timeout: Self.readTimeout
        )
        guard let snapshot = AgentDesktopSnapshot(data) else {
            throw ScreenDriverError.protocolFailure("snapshot returned no tree")
        }
        return snapshot
    }

    private func queryRef(label targetLabel: String, state: AgentDesktopSessionState, sessionID: String) async throws -> String {
        let snapshot = try await liveSnapshot(state.target, sessionID: sessionID, arguments: ["-i"])
        guard let ref = snapshot.uniqueRefMatching(label: targetLabel) else {
            throw ScreenDriverError.targetNotFound
        }
        let current = sessionStates[sessionID]
        let pixelScale = current?.pixelScale ?? state.pixelScale
        sessionStates[sessionID] = AgentDesktopSessionState(
            generation: state.generation,
            target: state.target,
            snapshotID: snapshot.snapshotID,
            elements: (current?.elements ?? [:]).merging(snapshot.elements(in: state.target, scale: pixelScale)) { _, newer in newer },
            pixelScale: pixelScale
        )
        return ref
    }

    private func focusedRef(in target: ScreenWindowTarget, sessionID: String) async throws -> String {
        let snapshot = try await liveSnapshot(target, sessionID: sessionID, arguments: ["--surface", "focused", "-i"])
        guard let ref = snapshot.focusedTextRef else {
            throw ScreenDriverError.targetNotFound
        }
        return ref
    }

    private func scrollableRef(in target: ScreenWindowTarget, sessionID: String) async throws -> String {
        let snapshot = try await liveSnapshot(target, sessionID: sessionID)
        let scrollable: Set<String> = ["scrollarea", "webarea", "list", "table", "outline", "textfield"]
        guard let ref = snapshot.actionable.first(where: { scrollable.contains($0.role) })?.ref
            ?? snapshot.actionable.first?.ref else {
            throw ScreenDriverError.targetNotFound
        }
        return ref
    }
}
