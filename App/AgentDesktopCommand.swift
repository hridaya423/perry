import Darwin
import Foundation
import PerryBrain

struct AgentDesktopFailure: Error, Equatable {
    let error: ScreenDriverError
    let mayHaveLanded: Bool
    var fieldValueAfter: String?

    func provesTextAbsent(_ text: String) -> Bool {
        fieldValueAfter.map { !$0.contains(text) } ?? false
    }
}

struct AgentDesktopCommand: Sendable {
    static let payloadLimit = 200_000
    static let payloadTooLong = AgentDesktopFailure(
        error: .toolRejected("That text is too long to type in one go. Split it into smaller parts."),
        mayHaveLanded: false
    )

    let executableURL: URL
    let environment: [String: String]

    func run(_ arguments: [String], payload: String? = nil, session: String, timeout: Duration) async throws -> JSONValue {
        try Task.checkCancellation()
        guard (payload?.utf8.count ?? 0) <= Self.payloadLimit else { throw Self.payloadTooLong }
        let process = Process()
        let output = Pipe()
        let collector = AgentDesktopOutput()
        process.executableURL = executableURL
        process.arguments = arguments + ["--session", session] + (payload.map { ["--", $0] } ?? [])
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let handle = output.fileHandleForReading
        handle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                collector.finish()
            } else {
                collector.append(chunk)
            }
        }
        process.terminationHandler = { _ in
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(200)) {
                handle.readabilityHandler = nil
                collector.finish()
            }
        }
        do {
            try process.run()
        } catch {
            handle.readabilityHandler = nil
            throw AgentDesktopFailure(error: .unavailable, mayHaveLanded: false)
        }
        let data: Data
        do {
            data = try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask { await collector.data() }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw AgentDesktopFailure(error: .requestTimedOut, mayHaveLanded: true)
                }
                defer { group.cancelAll() }
                do {
                    return try await group.next()!
                } catch {
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                    throw error
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AgentDesktopFailure(error: .requestTimedOut, mayHaveLanded: true)
        }
        return try Self.decode(data)
    }

    static func decode(_ data: Data) throws -> JSONValue {
        guard !data.isEmpty else {
            throw AgentDesktopFailure(error: .processExited, mayHaveLanded: true)
        }
        guard let envelope = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw AgentDesktopFailure(error: .protocolFailure("agent-desktop printed no JSON envelope"), mayHaveLanded: true)
        }
        if envelope["ok"]?.boolValue == true {
            return envelope["data"] ?? .null
        }
        guard let error = envelope["error"] else {
            throw AgentDesktopFailure(error: .protocolFailure("agent-desktop returned neither data nor an error"), mayHaveLanded: true)
        }
        let code = error["code"]?.stringValue ?? ""
        let delivery = error["disposition"]?["delivery"]?.stringValue
        let mayHaveLanded = delivery.map { $0 != "not_delivered" } ?? !preDeliveryCodes.contains(code)
        if code == "TIMEOUT", !mayHaveLanded {
            throw AgentDesktopFailure(error: .appBusy, mayHaveLanded: false)
        }
        let details = error["details"]
        if code == "STALE_REF", !mayHaveLanded, details?["check"]?.stringValue == "window_active" {
            throw AgentDesktopFailure(error: .windowNotInFront, mayHaveLanded: false)
        }
        let verifiedValue = details?["kind"]?.stringValue == "post_action_verification" ? details?["post_state"]?["value"]?.stringValue : nil
        throw AgentDesktopFailure(
            error: Self.error(code: code, message: error["message"]?.stringValue ?? ""),
            mayHaveLanded: mayHaveLanded,
            fieldValueAfter: verifiedValue
        )
    }

    private static let preDeliveryCodes: Set<String> = [
        "INVALID_ARGS", "PERM_DENIED", "STALE_REF", "SNAPSHOT_NOT_FOUND", "ELEMENT_NOT_FOUND", "WINDOW_NOT_FOUND",
        "APP_NOT_FOUND", "AMBIGUOUS_TARGET", "POLICY_DENIED", "ACTION_NOT_SUPPORTED", "PLATFORM_NOT_SUPPORTED",
    ]

    static func error(code: String, message: String) -> ScreenDriverError {
        switch code {
        case "PERM_DENIED":
            return .unavailable
        case "STALE_REF", "SNAPSHOT_NOT_FOUND", "ELEMENT_NOT_FOUND":
            return .staleTarget
        case "WINDOW_NOT_FOUND", "APP_NOT_FOUND":
            return .targetNotFound
        case "AMBIGUOUS_TARGET":
            return .noTargetWindow
        case "POLICY_DENIED", "ACTION_NOT_SUPPORTED", "PLATFORM_NOT_SUPPORTED":
            return .unsupportedAction
        case "APP_UNRESPONSIVE":
            return .actionUnanswered
        case "TIMEOUT":
            return .requestTimedOut
        case "ACTION_FAILED":
            return .toolRejected(message)
        default:
            return .protocolFailure(message.isEmpty ? code : message)
        }
    }

    static func environment(stateDirectory: URL) -> [String: String] {
        var environment = ["AGENT_DESKTOP_HOME": stateDirectory.path]
        let inherited = ProcessInfo.processInfo.environment
        for key in ["HOME", "TMPDIR", "LANG", "LC_ALL"] {
            if let value = inherited[key] {
                environment[key] = value
            }
        }
        return environment
    }
}

private final class AgentDesktopOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var finished = false
    private var waiter: CheckedContinuation<Data, Never>?

    func append(_ chunk: Data) {
        lock.withLock { buffer.append(chunk) }
    }

    func finish() {
        let resumed: (CheckedContinuation<Data, Never>, Data)? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            defer { waiter = nil }
            return waiter.map { ($0, buffer) }
        }
        if let resumed {
            resumed.0.resume(returning: resumed.1)
        }
    }

    func data() async -> Data {
        await withCheckedContinuation { continuation in
            let ready: Data? = lock.withLock {
                guard finished else {
                    waiter = continuation
                    return nil
                }
                return buffer
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}

enum AgentDesktopHosts {
    static func terminate(executableURL: URL, session: String) {
        let groups = hostProcessGroups(executableURL: executableURL, session: session)
        for group in groups {
            kill(-group, SIGTERM)
        }
        let deadline = Date().addingTimeInterval(0.2)
        while Date() < deadline, groups.contains(where: { kill(-$0, 0) == 0 }) {
            usleep(5_000)
        }
        for group in groups where kill(-group, 0) == 0 {
            kill(-group, SIGKILL)
        }
    }

    private static func hostProcessGroups(executableURL: URL, session: String) -> [pid_t] {
        let path = executableURL.resolvingSymlinksInPath().path
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        return pids.prefix(Int(filled)).compactMap { pid -> pid_t? in
            guard pid > 0, executablePath(of: pid) == path else { return nil }
            let environment = Self.environment(of: pid)
            guard environment["AGENT_DESKTOP_INTERNAL_COMMAND_HOST"] == "1" else { return nil }
            guard environment["AGENT_DESKTOP_SESSION"] == session else { return nil }
            let group = getpgid(pid)
            return group == pid ? group : nil
        }
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
    }

    private static func environment(of pid: pid_t) -> [String: String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [:] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [:] }
        let argumentCount = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        let strings = buffer[MemoryLayout<Int32>.size..<size]
            .split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
        let variables = strings.dropFirst(1 + Int(argumentCount))
        return variables.reduce(into: [:]) { environment, entry in
            guard let separator = entry.firstIndex(of: "=") else { return }
            environment[String(entry[..<separator])] = String(entry[entry.index(after: separator)...])
        }
    }
}
