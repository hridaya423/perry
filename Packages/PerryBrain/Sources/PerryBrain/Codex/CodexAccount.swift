import Foundation

public enum CodexAccountStatus: Equatable, Sendable {
    case signedIn(email: String, plan: String)
    case signedOut
    case unknown
}

public struct CodexRateLimits: Equatable, Sendable {
    public var primaryUsedPercent: Double?
    public var secondaryUsedPercent: Double?
    public var primaryResetsAt: Date?
    public var planType: String?

    public init(primaryUsedPercent: Double? = nil, secondaryUsedPercent: Double? = nil, primaryResetsAt: Date? = nil, planType: String? = nil) {
        self.primaryUsedPercent = primaryUsedPercent
        self.secondaryUsedPercent = secondaryUsedPercent
        self.primaryResetsAt = primaryResetsAt
        self.planType = planType
    }
}

public enum CodexLoginEvent: Equatable, Sendable {
    case completed(success: Bool, loginID: String?, error: String?)
}

public struct CodexAccount: Sendable {
    private let process: CodexAppServerProcess

    public init(process: CodexAppServerProcess) {
        self.process = process
    }

    public func status() async -> CodexAccountStatus {
        do {
            let result = try await connection().request("account/read")
            guard let account = result["account"], account != .null,
                  let type = account["type"]?.stringValue else {
                return .signedOut
            }
            switch type {
            case "chatgpt":
                return .signedIn(
                    email: account["email"]?.stringValue ?? "",
                    plan: account["planType"]?.stringValue ?? "unknown"
                )
            default:
                return .signedIn(email: type, plan: type)
            }
        } catch {
            return .unknown
        }
    }

    public func signIn() async throws -> URL? {
        let result = try await connection().request("account/login/start", params: .object([
            "type": .string("chatgpt"),
        ]))
        guard let raw = result["authUrl"]?.stringValue, let url = URL(string: raw) else {
            return nil
        }
        return url
    }

    public func signOut() async throws {
        _ = try await connection().request("account/logout")
    }

    public func rateLimits() async throws -> CodexRateLimits? {
        let result = try await connection().request("account/rateLimits/read")
        guard let snapshot = result["rateLimits"]?.objectValue else { return nil }
        var limits = CodexRateLimits()
        limits.planType = snapshot["planType"]?.stringValue
        if let primary = snapshot["primary"]?.objectValue {
            limits.primaryUsedPercent = primary["usedPercent"]?.doubleValue
            if let resetsAt = primary["resetsAt"]?.doubleValue {
                limits.primaryResetsAt = Date(timeIntervalSince1970: resetsAt)
            }
        }
        if let secondary = snapshot["secondary"]?.objectValue {
            limits.secondaryUsedPercent = secondary["usedPercent"]?.doubleValue
        }
        return limits
    }

    /// Subscribes before returning, so call this before `signIn()` to never miss completion.
    public func loginEvents() async throws -> AsyncStream<CodexLoginEvent> {
        let events = try await connection().events
        return AsyncStream { continuation in
            let task = Task {
                for await event in events {
                    guard case .notification(let note) = event,
                          note.method == "account/login/completed" else { continue }
                    continuation.yield(.completed(
                        success: note.params["success"]?.boolValue ?? false,
                        loginID: note.params["loginId"]?.stringValue,
                        error: note.params["error"]?.stringValue
                    ))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func connection() async throws -> JSONRPCConnection {
        try await process.connection()
    }
}
