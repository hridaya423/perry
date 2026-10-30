import AppKit
import Darwin
import Foundation
import PerryBrain
import PerryCore
import PerryRuntimes

private struct DriverArguments: Encodable {
    var pid: Int32?
    var windowId: Int64?
    var session: String?
    var deliveryMode: String?
    var elementToken: String?
    var x: Double?
    var y: Double?
    var text: String?
    var value: String?
    var delayMs: Int?
    var direction: String?
    var amount: Int?
    var by: String?
    var key: String?
    var modifiers: [String]?
    var keys: [String]?
    var fromX: Double?
    var fromY: Double?
    var toX: Double?
    var toY: Double?
    var durationMs: Int?
    var steps: Int?
    var onScreenOnly: Bool?
    var includeScreenshot: Bool?
    var query: String?
    var maxElements: Int?
    var timeoutMs: Int?
    var treeFormat: String?
}

private struct RunStepsArguments: Encodable {
    struct Step: Encodable {
        let tool: String
        let args: DriverArguments
    }

    let steps: [Step]
    let session: String
    let foregroundFallback: Bool
    let delayMs: Int
}

private struct DriverCall {
    let tool: String
    var arguments: DriverArguments
}

private struct CuaOwnedProcess {
    let process: Process
    let processGroup: pid_t?

    var hasExited: Bool {
        if let processGroup {
            return kill(-processGroup, 0) == -1 && errno == ESRCH
        }
        // Foundation's isRunning lags while a zombie waits to be reaped, so reap it here.
        if !process.isRunning { return true }
        var status: Int32 = 0
        let waited = waitpid(process.processIdentifier, &status, WNOHANG)
        if waited == process.processIdentifier { return true }
        if waited == -1 && errno == ECHILD { return true }
        return kill(process.processIdentifier, 0) == -1 && errno == ESRCH
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

private struct CuaSessionState: Sendable {
    let generation: UInt64
    let target: CuaWindowTarget
    let snapshotID: String?
    let elementLabels: [String: String]
}

private struct CuaConnection {
    let generation: UInt64
    let process: Process
    let rpc: JSONRPCConnection
    let input: FileHandle
    let output: FileHandle
    let monitor: Task<Void, Never>
    var initialization: Task<Void, Error>?
}

private enum CuaConfigurationSource {
    case discover
    case resolved(CuaDriverConfiguration?)
}

actor CuaDriverClient {
    private static let requestTimeout = Duration.seconds(15)
    private static let readTimeout = Duration.seconds(6)
    private static let foregroundOnlyBundleIDs: Set<String> = ["com.apple.finder"]

    private let allowsRestart: Bool
    private let allowsForegroundInput: Bool
    private var configurationSource: CuaConfigurationSource
    private var connection: CuaConnection?
    private var nextConnectionGeneration: UInt64 = 0
    private var startedSessions: [String: UInt64] = [:]
    private var sessionStates: [String: CuaSessionState] = [:]
    private var sessionTargets: [String: CuaWindowTarget] = [:]
    private var ownedProcesses: [UInt64: CuaOwnedProcess] = [:]
    private var retired = false
    private var retirementTask: Task<Void, Error>?

    init(allowsRestart: Bool = true, allowsForegroundInput: Bool = false) {
        self.allowsRestart = allowsRestart
        self.allowsForegroundInput = allowsForegroundInput
        configurationSource = .discover
    }

    init(configuration: CuaDriverConfiguration?, allowsRestart: Bool = true, allowsForegroundInput: Bool = false) {
        self.allowsRestart = allowsRestart
        self.allowsForegroundInput = allowsForegroundInput
        configurationSource = .resolved(configuration)
    }

    func health() async -> CuaDriverHealth {
        guard resolvedConfiguration() != nil else {
            return CuaDriverHealth(
                ready: false,
                summary: "Screen control isn’t available. Reinstall Perry or set its path in Settings > Brain."
            )
        }
        do {
            let generation = try await ensureStarted()
            let output = try await callTool("check_permissions", DriverArguments(), generation: generation)
            let report = output.structure(CuaPermissionReport.self)
            guard report?.source?.attribution == "host", report?.source?.embedded == true else {
                return CuaDriverHealth(
                    ready: false,
                    summary: "Screen control couldn’t confirm that Perry holds its permissions."
                )
            }
            guard report?.accessibility == true, report?.screenRecording == true else {
                return CuaDriverHealth(
                    ready: false,
                    summary: "I need Accessibility and Screen Recording access. Turn both on for Perry in System Settings."
                )
            }
            return CuaDriverHealth(ready: true, summary: "Screen control is ready.")
        } catch {
            return CuaDriverHealth(ready: false, summary: "Screen control isn’t responding. Try again.")
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
        sessionTargets[sessionID] = nil
        let generation = try await ensureSession(sessionID)
        let windows = try await listWindows(generation: generation, sessionID: sessionID)
        guard let target = selectTarget(from: windows, hint: hint) else {
            throw CuaDriverError.noTargetWindow
        }
        try ensureTargetAllowed(target)
        guard connection?.generation == generation, startedSessions[sessionID] == generation else {
            throw CuaDriverError.processExited
        }
        sessionTargets[sessionID] = target
        return target
    }

    func capture(resolvedTarget: CuaWindowTarget, sessionID: String, includeScreenshot: Bool = true) async throws -> CuaCapturedWindow {
        try Task.checkCancellation()
        let generation = try validateResolvedTarget(resolvedTarget, sessionID: sessionID)
        let output = try await callTool(
            "get_window_state",
            windowStateArguments(resolvedTarget, sessionID: sessionID, includeScreenshot: includeScreenshot),
            generation: generation,
            timeout: Self.readTimeout
        )
        let screenshotData = output.images.first ?? Data()
        if includeScreenshot, screenshotData.isEmpty {
            throw CuaDriverError.noScreenshot
        }
        guard connection?.generation == generation, startedSessions[sessionID] == generation else {
            throw CuaDriverError.processExited
        }
        let state = output.structure(CuaWindowState.self)
        sessionStates[sessionID] = CuaSessionState(
            generation: generation,
            target: resolvedTarget,
            snapshotID: state?.snapshotId,
            elementLabels: state?.labels ?? [:]
        )
        sessionTargets[sessionID] = resolvedTarget
        return CuaCapturedWindow(
            target: resolvedTarget,
            screenshotData: screenshotData,
            screenshotMIMEType: output.imageMIMEType ?? "image/png",
            accessibilitySnapshot: state?.actionTokens,
            accessibilitySnapshotModel: state?.guideSnapshot(target: resolvedTarget),
            snapshotID: state?.snapshotId,
            elementDetails: state?.details ?? [:],
            treeComplete: state?.truncated != true
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
                  target.bundleID.lowercased() == expected.bundleID.lowercased() else {
                throw CuaDriverError.targetMismatch
            }
        }
        let output = try await perform(action.operation, state: state, sessionID: sessionID)
        return StepResult(
            stepID: action.stepID,
            success: true,
            message: output.text.isEmpty ? action.operation.defaultMessage : output.text
        )
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
        var arguments = windowArguments(resolvedTarget, sessionID: sessionID)
        arguments.text = text
        arguments.delayMs = 10
        let output = try await callTool("type_text", arguments, generation: generation)
        guard output.effectConfirmed else {
            throw CuaDriverError.toolRejected("I couldn’t confirm the text went into the field.")
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
        sessionTargets[sessionID] = current
        return current
    }

    func shutdown() async {
        forgetSessions()
        sessionTargets.removeAll()
        await tearDown(terminate: true)
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

    static func embeddedEnvironment(configuration: CuaDriverConfiguration) -> [String: String] {
        var environment: [String: String] = [
            "CUA_DRIVER_EMBEDDED": "1",
            "CUA_DRIVER_HOST_BUNDLE_ID": configuration.hostBundleID,
            "CUA_DRIVER_PERMISSION_MODE": "bounded",
            "CUA_DRIVER_CAPABILITY_MANIFEST_FILE": configuration.capabilityManifestURL.path,
            "CUA_DRIVER_CAPABILITY_MANIFEST_APPROVED": "1",
            "CUA_DRIVER_RS_UPDATE_CHECK": "0",
            "CUA_DRIVER_RS_TELEMETRY_ENABLED": "0",
            "CUA_DRIVER_WINDOW_CHANGE_TIMEOUT_MS": "200",
        ]
        let inherited = ProcessInfo.processInfo.environment
        for key in ["HOME", "TMPDIR", "LANG", "LC_ALL"] {
            if let value = inherited[key] {
                environment[key] = value
            }
        }
        return environment
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

    private func ensureSession(_ sessionID: String) async throws -> UInt64 {
        let generation = try await ensureStarted()
        if startedSessions[sessionID] == generation { return generation }
        var arguments = DriverArguments()
        arguments.session = sessionID
        _ = try await callTool("start_session", arguments, generation: generation)
        guard connection?.generation == generation else { throw CuaDriverError.processExited }
        startedSessions[sessionID] = generation
        return generation
    }

    private func ensureStarted() async throws -> UInt64 {
        try Task.checkCancellation()
        guard !retired else { throw CuaDriverError.processExited }
        reapExitedProcesses()
        if let connection {
            if connection.process.isRunning {
                if let initialization = connection.initialization {
                    try await initialization.value
                }
                try Task.checkCancellation()
                return connection.generation
            }
            await failConnection(generation: connection.generation)
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
        process.arguments = ["mcp", "--direct", "--embedded", "--host-bundle-id", configuration.hostBundleID]
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
        ownedProcesses[generation] = CuaOwnedProcess(process: process, processGroup: getpgid(pid) == pid ? pid : nil)

        let input = inputPipe.fileHandleForWriting
        let output = outputPipe.fileHandleForReading
        let rpc = JSONRPCConnection(readHandle: output, writeHandle: input, stampsVersion: true)
        let monitor = Task { [weak self] in
            for await event in await rpc.events {
                if case .closed = event { break }
            }
            guard !Task.isCancelled else { return }
            await self?.failConnection(generation: generation)
        }
        connection = CuaConnection(
            generation: generation,
            process: process,
            rpc: rpc,
            input: input,
            output: output,
            monitor: monitor,
            initialization: nil
        )
        let initialization = Task { [weak self] () throws -> Void in
            guard let self else { throw CuaDriverError.processExited }
            do {
                await rpc.start()
                _ = try await self.send(rpc, generation: generation, method: "initialize", params: .object([
                    "protocolVersion": .string("2025-06-18"),
                    "capabilities": .object([:]),
                    "clientInfo": .object(["name": .string("Perry"), "version": .string("1.0")]),
                ]), timeout: Self.requestTimeout)
                try await rpc.notify("notifications/initialized")
                await self.markConnectionReady(generation: generation)
            } catch {
                await self.failConnection(generation: generation)
                throw error
            }
        }
        connection?.initialization = initialization
        try await initialization.value
        return generation
    }

    private func markConnectionReady(generation: UInt64) {
        guard connection?.generation == generation else { return }
        connection?.initialization = nil
    }

    private func callTool(
        _ tool: String,
        _ arguments: DriverArguments,
        generation: UInt64,
        timeout: Duration? = nil
    ) async throws -> CuaToolOutput {
        do {
            return try await invoke(tool, arguments, generation: generation, timeout: timeout)
        } catch CuaDriverError.toolRejected(let detail)
            where allowsForegroundInput && arguments.deliveryMode == "background" && detail.contains("Background input refused") {
            var foreground = arguments
            foreground.deliveryMode = "foreground"
            return try await invoke(tool, foreground, generation: generation, timeout: timeout)
        }
    }

    private func invoke(
        _ tool: String,
        _ arguments: some Encodable,
        generation: UInt64,
        timeout: Duration?
    ) async throws -> CuaToolOutput {
        guard !retired, let connection, connection.generation == generation else {
            throw CuaDriverError.processExited
        }
        PerfMark.markDynamic("cua.\(tool).begin")
        defer { PerfMark.markDynamic("cua.\(tool).end") }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let encoded = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(arguments))
        let result = try await send(
            connection.rpc,
            generation: generation,
            method: "tools/call",
            params: .object(["name": .string(tool), "arguments": encoded]),
            timeout: timeout ?? Self.requestTimeout
        )
        let output = CuaToolOutput(result)
        if output.isError {
            throw CuaDriverError.toolRejected(output.text)
        }
        return output
    }

    private func send(
        _ rpc: JSONRPCConnection,
        generation: UInt64,
        method: String,
        params: JSONValue,
        timeout: Duration
    ) async throws -> JSONValue {
        try Task.checkCancellation()
        do {
            return try await withThrowingTaskGroup(of: JSONValue.self) { group in
                group.addTask { try await rpc.request(method, params: params) }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw CuaDriverError.requestTimedOut
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch CuaDriverError.requestTimedOut {
            await failConnection(generation: generation)
            throw CuaDriverError.requestTimedOut
        } catch let error as JSONRPCError where error.code != -32098 {
            throw CuaDriverError.protocolFailure(error.message)
        } catch {
            throw CuaDriverError.processExited
        }
    }

    private func failConnection(generation: UInt64) async {
        guard connection?.generation == generation else { return }
        forgetSessions()
        await tearDown(terminate: true)
    }

    private func forgetSessions() {
        startedSessions.removeAll()
        sessionStates.removeAll()
    }

    private func tearDown(terminate: Bool) async {
        guard let connection else { return }
        self.connection = nil
        connection.monitor.cancel()
        connection.initialization?.cancel()
        await connection.rpc.close()
        connection.input.closeFile()
        connection.output.closeFile()
        if terminate, connection.process.isRunning {
            connection.process.terminate()
        }
    }

    private func finishRetirement() async throws {
        let started = ContinuousClock.now
        forgetSessions()
        sessionTargets.removeAll()
        await tearDown(terminate: false)
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

    private func listWindows(generation: UInt64, sessionID: String) async throws -> [CuaWindowTarget] {
        var arguments = DriverArguments()
        arguments.onScreenOnly = false
        let output = try await callTool("list_windows", arguments, generation: generation, timeout: Self.readTimeout)
        guard let list = output.structure(CuaWindowList.self) else {
            throw CuaDriverError.protocolFailure("list_windows returned no window list")
        }
        return list.windows.compactMap(\.value).compactMap { window in
            let bundleID = window.bundleId ?? NSRunningApplication(processIdentifier: window.pid)?.bundleIdentifier
            guard let bundleID, !bundleID.isEmpty else { return nil }
            return CuaWindowTarget(
                bundleID: bundleID,
                processID: window.pid,
                windowID: window.windowId,
                connectionGeneration: generation,
                sessionID: sessionID,
                title: window.title,
                x: window.bounds.x,
                y: window.bounds.y,
                width: window.bounds.width,
                height: window.bounds.height,
                zIndex: window.zIndex,
                isOnScreen: window.isOnScreen ?? true,
                isOnCurrentSpace: window.onCurrentSpace ?? true
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
        guard connection?.generation == generation, startedSessions[sessionID] == generation else {
            throw CuaDriverError.processExited
        }
        try ensureTargetAllowed(target)
        return generation
    }

    private func liveWindow(matching target: CuaWindowTarget, generation: UInt64, sessionID: String) async throws -> CuaWindowTarget {
        let current = try await listWindows(generation: generation, sessionID: sessionID)
            .first { $0.processID == target.processID && $0.windowID == target.windowID }
        guard let current else {
            throw CuaDriverError.targetNotFound
        }
        try ensureTargetAllowed(current)
        return current
    }

    private func refreshResolvedTarget(_ target: CuaWindowTarget, sessionID: String) async throws -> CuaWindowTarget {
        let generation = try validateResolvedTarget(target, sessionID: sessionID)
        return try await liveWindow(matching: target, generation: generation, sessionID: sessionID)
    }

    private func refreshSessionTarget(_ sessionID: String) async throws -> CuaSessionState {
        if let previous = sessionStates[sessionID], previous.generation == connection?.generation {
            let currentTarget = try await refreshResolvedTarget(previous.target, sessionID: sessionID)
            let refreshed = CuaSessionState(
                generation: previous.generation,
                target: currentTarget,
                snapshotID: previous.snapshotID,
                elementLabels: previous.elementLabels
            )
            sessionStates[sessionID] = refreshed
            sessionTargets[sessionID] = currentTarget
            return refreshed
        }
        guard let boundTarget = sessionTargets[sessionID],
              let generation = connection?.generation,
              startedSessions[sessionID] == generation else {
            throw CuaDriverError.targetNotFound
        }
        let currentTarget = try await liveWindow(matching: boundTarget, generation: generation, sessionID: sessionID)
        let state = CuaSessionState(generation: generation, target: currentTarget, snapshotID: nil, elementLabels: [:])
        sessionStates[sessionID] = state
        sessionTargets[sessionID] = currentTarget
        return state
    }

    private func windowArguments(_ target: CuaWindowTarget, sessionID: String) -> DriverArguments {
        var arguments = DriverArguments()
        arguments.pid = target.processID
        arguments.windowId = target.windowID
        arguments.session = sessionID
        let foreground = allowsForegroundInput && Self.foregroundOnlyBundleIDs.contains(target.bundleID.lowercased())
        arguments.deliveryMode = foreground ? "foreground" : "background"
        return arguments
    }

    private func windowStateArguments(
        _ target: CuaWindowTarget,
        sessionID: String,
        includeScreenshot: Bool,
        query: String? = nil
    ) -> DriverArguments {
        var arguments = DriverArguments()
        arguments.pid = target.processID
        arguments.windowId = target.windowID
        arguments.session = sessionID
        arguments.includeScreenshot = includeScreenshot
        arguments.query = query
        arguments.maxElements = 1000
        arguments.timeoutMs = 3000
        arguments.treeFormat = "elements"
        return arguments
    }

    private func perform(_ operation: ComputerAction.Operation, state: CuaSessionState, sessionID: String) async throws -> CuaToolOutput {
        if case .steps(let operations) = operation {
            var steps: [RunStepsArguments.Step] = []
            for operation in operations {
                var call = try await request(for: operation, state: state, sessionID: sessionID)
                call.arguments.session = nil
                steps.append(RunStepsArguments.Step(tool: call.tool, args: call.arguments))
            }
            return try await invoke(
                "run_steps",
                RunStepsArguments(steps: steps, session: sessionID, foregroundFallback: allowsForegroundInput, delayMs: 300),
                generation: state.generation,
                timeout: nil
            )
        }
        let call = try await request(for: operation, state: state, sessionID: sessionID)
        do {
            return try await callTool(call.tool, call.arguments, generation: state.generation)
        } catch let error as CuaDriverError where error.isStaleTarget {
            guard operation.target?.hasFreshSelector == true else { throw error }
            let refreshed = try await request(for: operation, state: state, sessionID: sessionID, trustsSnapshotToken: false)
            return try await callTool(refreshed.tool, refreshed.arguments, generation: state.generation)
        }
    }

    private func request(
        for operation: ComputerAction.Operation,
        state: CuaSessionState,
        sessionID: String,
        trustsSnapshotToken: Bool = true
    ) async throws -> DriverCall {
        func arguments(_ target: ComputerTarget?, pointer: Bool, requiresTarget: Bool = true) async throws -> DriverArguments {
            if pointer, let target {
                return try await pointerArguments(target, state: state, sessionID: sessionID, trustsSnapshotToken: trustsSnapshotToken)
            }
            return try await targetArguments(
                target, state: state, sessionID: sessionID,
                requiresTarget: requiresTarget && target != nil, trustsSnapshotToken: trustsSnapshotToken
            )
        }
        switch operation {
        case .click(let target):
            return DriverCall(tool: "click", arguments: try await arguments(target, pointer: true))
        case .rightClick(let target):
            return DriverCall(tool: "right_click", arguments: try await arguments(target, pointer: true))
        case .doubleClick(let target):
            return DriverCall(tool: "double_click", arguments: try await arguments(target, pointer: true))
        case .typeText(let text, let target):
            var call = DriverCall(tool: "type_text", arguments: try await arguments(target, pointer: true, requiresTarget: false))
            call.arguments.text = text
            call.arguments.delayMs = 10
            return call
        case .setValue(let value, let target):
            guard let token = try await elementToken(for: target, state: state, sessionID: sessionID, trustsSnapshotToken: trustsSnapshotToken) else {
                throw CuaDriverError.targetNotFound
            }
            var call = DriverCall(tool: "set_value", arguments: DriverArguments())
            call.arguments.session = sessionID
            call.arguments.elementToken = token
            call.arguments.value = value
            return call
        case .scroll(let direction, let amount, let by, let target):
            var call = DriverCall(tool: "scroll", arguments: try await arguments(target, pointer: false, requiresTarget: false))
            call.arguments.direction = direction.rawValue
            call.arguments.amount = amount
            call.arguments.by = by?.rawValue
            return call
        case .pressKey(let key, let modifiers, let target):
            var call = DriverCall(tool: "press_key", arguments: try await arguments(target, pointer: false, requiresTarget: false))
            call.arguments.key = key
            call.arguments.modifiers = modifiers
            return call
        case .hotkey(let keys, let target):
            var call = DriverCall(tool: "hotkey", arguments: try await arguments(target, pointer: false, requiresTarget: false))
            call.arguments.keys = keys
            return call
        case .drag(let from, let to, let durationMilliseconds, let steps):
            var call = DriverCall(tool: "drag", arguments: windowArguments(state.target, sessionID: sessionID))
            call.arguments.fromX = from.x
            call.arguments.fromY = from.y
            call.arguments.toX = to.x
            call.arguments.toY = to.y
            call.arguments.durationMs = durationMilliseconds
            call.arguments.steps = steps
            return call
        case .steps:
            throw CuaDriverError.unsupportedAction
        }
    }

    private func targetArguments(
        _ target: ComputerTarget?,
        state: CuaSessionState,
        sessionID: String,
        requiresTarget: Bool,
        trustsSnapshotToken: Bool
    ) async throws -> DriverArguments {
        var arguments = windowArguments(state.target, sessionID: sessionID)
        if let token = try await elementToken(for: target, state: state, sessionID: sessionID, trustsSnapshotToken: trustsSnapshotToken) {
            arguments.elementToken = token
        } else if let point = target?.point {
            arguments.x = point.x
            arguments.y = point.y
        } else if requiresTarget {
            throw CuaDriverError.targetNotFound
        }
        return arguments
    }

    private func pointerArguments(
        _ target: ComputerTarget,
        state: CuaSessionState,
        sessionID: String,
        trustsSnapshotToken: Bool
    ) async throws -> DriverArguments {
        do {
            return try await targetArguments(
                target, state: state, sessionID: sessionID, requiresTarget: true, trustsSnapshotToken: trustsSnapshotToken
            )
        } catch CuaDriverError.targetNotFound where target.point != nil {
            return try await targetArguments(
                .point(target.point!), state: state, sessionID: sessionID, requiresTarget: true, trustsSnapshotToken: trustsSnapshotToken
            )
        }
    }

    private func elementToken(
        for target: ComputerTarget?,
        state: CuaSessionState,
        sessionID: String,
        trustsSnapshotToken: Bool
    ) async throws -> String? {
        guard let target, target.hasFreshSelector else { return nil }
        if trustsSnapshotToken, let id = target.id, let snapshotID = state.snapshotID, id.hasPrefix("\(snapshotID):") {
            return id
        }
        if let label = target.label, !label.isEmpty {
            return try await queryElementToken(label: label, state: state, sessionID: sessionID)
        }
        guard let id = target.id else { return nil }
        if let label = state.elementLabels[id] {
            return try await queryElementToken(label: label, state: state, sessionID: sessionID)
        }
        let token = id.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard token.hasPrefix("s") else {
            throw CuaDriverError.targetNotFound
        }
        return token
    }

    private func queryElementToken(label targetLabel: String, state: CuaSessionState, sessionID: String) async throws -> String {
        let output = try await callTool(
            "get_window_state",
            windowStateArguments(state.target, sessionID: sessionID, includeScreenshot: false, query: targetLabel),
            generation: state.generation,
            timeout: Self.readTimeout
        )
        guard let window = output.structure(CuaWindowState.self),
              let token = window.uniqueTokenMatching(label: targetLabel) else {
            throw CuaDriverError.targetNotFound
        }
        let current = sessionStates[sessionID]
        sessionStates[sessionID] = CuaSessionState(
            generation: state.generation,
            target: state.target,
            snapshotID: window.snapshotId ?? current?.snapshotID,
            elementLabels: (current?.elementLabels ?? [:]).merging(window.labels) { _, newer in newer }
        )
        return token
    }
}

extension AppController {
    func reloadCuaDriverConfiguration() {
        guard isIdle, !subsystems.foreground.supervisorActive, !subsystems.backgroundTasks.hasRunningTasks, !subsystems.foreground.startIsInFlight else {
            sessionStatus = "Finish your running tasks before changing screen control."
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await subsystems.workers.reloadConfiguration()
                sessionStatus = "Screen control updated."
            } catch {
                sessionStatus = "I couldn’t update screen control. Try again."
            }
        }
    }
}
