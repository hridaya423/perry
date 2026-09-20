import CryptoKit
import Foundation
import PerryCore

public enum ExecutionScope: String, Codable, Hashable, Sendable {
    case computerControl
    case workspaceWrite
    case integrationWrite
    case sandboxedExecution
}

public enum ExecutablePlanError: Error, Equatable, Sendable {
    case invalid(String)
}

public struct ExecutionPlan: Codable, Sendable {
    public static let currentVersion = 1
    public let schemaVersion: Int
    public let planID: UUID
    public let taskID: TaskID
    public let goal: String
    public let actions: [ExecutableAction]
    public let requestedScopes: Set<ExecutionScope>

    public init(
        schemaVersion: Int = currentVersion,
        planID: UUID = UUID(),
        taskID: TaskID,
        goal: String,
        actions: [ExecutableAction],
        requestedScopes: Set<ExecutionScope>
    ) throws {
        guard schemaVersion == Self.currentVersion else {
            throw ExecutablePlanError.invalid("unsupported plan schema")
        }
        guard !taskID.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !actions.isEmpty else {
            throw ExecutablePlanError.invalid("plan requires a task, goal, and actions")
        }
        guard Set(actions.map(\.id)).count == actions.count else {
            throw ExecutablePlanError.invalid("action IDs must be unique")
        }
        let required = Set(actions.flatMap { $0.operation.requiredScopes })
        guard required == requestedScopes else {
            throw ExecutablePlanError.invalid("plan scopes must match its effects")
        }
        self.schemaVersion = schemaVersion
        self.planID = planID
        self.taskID = taskID
        self.goal = goal
        self.actions = actions
        self.requestedScopes = requestedScopes
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, planID, taskID, goal, actions, requestedScopes
    }

    public init(from decoder: Decoder) throws {
        let values = try PlanDecodingFields(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        try self.init(
            schemaVersion: values.decode(Int.self, "schemaVersion"),
            planID: values.decode(UUID.self, "planID"),
            taskID: values.decode(TaskID.self, "taskID"),
            goal: values.decode(String.self, "goal"),
            actions: values.decode([ExecutableAction].self, "actions"),
            requestedScopes: Set(values.decode([ExecutionScope].self, "requestedScopes"))
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(planID, forKey: .planID)
        try values.encode(taskID, forKey: .taskID)
        try values.encode(goal, forKey: .goal)
        try values.encode(actions, forKey: .actions)
        try values.encode(requestedScopes.sorted { $0.rawValue < $1.rawValue }, forKey: .requestedScopes)
    }

    public func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public func approvalDigest() throws -> String {
        SHA256.hash(data: try canonicalData()).map { String(format: "%02x", $0) }.joined()
    }
}

public struct ExecutableAction: Codable, Sendable, Identifiable {
    public let id: ActionID
    public let summary: String
    public let timeout: TimeInterval
    public let approvalRequirement: ApprovalScope
    public let idempotency: IdempotencyPolicy
    public let operation: Operation
    public let postcondition: Postcondition

    public init(
        id: ActionID,
        summary: String,
        timeout: TimeInterval = 30,
        approvalRequirement: ApprovalScope,
        idempotency: IdempotencyPolicy = .nonIdempotent,
        operation: Operation,
        postcondition: Postcondition
    ) throws {
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              timeout.isFinite, timeout > 0 else {
            throw ExecutablePlanError.invalid("action requires a summary and positive finite timeout")
        }
        if case .keyed(let key) = idempotency {
            try Self.requireText(key)
        }
        guard operation.requiredScopes.isEmpty || approvalRequirement != .none else {
            throw ExecutablePlanError.invalid("effectful action requires declared approval")
        }
        guard approvalRequirement >= operation.policy.minimumApproval else {
            throw ExecutablePlanError.invalid("approval is below the operation's policy floor")
        }
        try operation.validate(postcondition: postcondition)
        self.id = id
        self.summary = summary
        self.timeout = timeout
        self.approvalRequirement = approvalRequirement
        self.idempotency = idempotency
        self.operation = operation
        self.postcondition = postcondition
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, summary, timeout, approvalRequirement, idempotency, operation, postcondition
    }

    public init(from decoder: Decoder) throws {
        let values = try PlanDecodingFields(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        try self.init(
            id: values.decode(ActionID.self, "id"),
            summary: values.decode(String.self, "summary"),
            timeout: values.decode(TimeInterval.self, "timeout"),
            approvalRequirement: values.decode(ApprovalScope.self, "approvalRequirement"),
            idempotency: values.decode(IdempotencyPolicy.self, "idempotency"),
            operation: Operation.decodeStrict(from: values.decoder("operation")),
            postcondition: Postcondition.decodeStrict(from: values.decoder("postcondition"))
        )
    }

    public enum Operation: Codable, Equatable, Sendable {
        case computer(window: WindowIdentity, command: ComputerCommand)
        case integration(accountID: String, command: IntegrationCommand)
        case shell(workspace: URL, executable: ExecutableIdentity, confinement: SandboxConfinement, command: SandboxedCommand)
        case transform(workspace: URL, command: FileTransform)
        case askUser(prompt: String, choices: [String])

        public var requiredScopes: Set<ExecutionScope> {
            switch self {
            case .computer: return [.computerControl]
            case .integration: return [.integrationWrite]
            case .shell(_, _, let confinement, _):
                return confinement == .workspaceReadWrite
                    ? [.sandboxedExecution, .workspaceWrite]
                    : [.sandboxedExecution]
            case .transform: return [.workspaceWrite]
            case .askUser: return []
            }
        }

        fileprivate func validate(postcondition: Postcondition) throws {
            switch self {
            case .computer(let window, let command):
                try window.validate()
                try command.validate()
                switch postcondition {
                case .elementValue: break
                case .visualChange(let baselineSHA256): try ExecutableAction.requireDigest(baselineSHA256)
                default: throw ExecutablePlanError.invalid("computer action requires observable window evidence")
                }
            case .integration(let accountID, let command):
                try ExecutableAction.requireText(accountID)
                try command.validate()
                guard case .integrationResource(let identifier, let expectedText) = postcondition else {
                    throw ExecutablePlanError.invalid("integration action requires resource read-back")
                }
                try ExecutableAction.requireText(identifier)
                try ExecutableAction.requireText(expectedText)
            case .shell(let workspace, let executable, _, let command):
                try ExecutableAction.requireWorkspace(workspace)
                try executable.validate()
                switch command {
                case .registeredCommand(let arguments):
                    guard arguments.allSatisfy({ !$0.contains("\0") }) else {
                        throw ExecutablePlanError.invalid("command argument contains NUL")
                    }
                case .codingTask(let runtimeID, let prompt):
                    try ExecutableAction.requireText(runtimeID)
                    try ExecutableAction.requireText(prompt)
                }
                guard case .workspaceFileContents(let path, _) = postcondition else {
                    throw ExecutablePlanError.invalid("shell action requires a declared workspace result")
                }
                try ExecutableAction.requireRelativePath(path)
            case .transform(let workspace, let command):
                try ExecutableAction.requireWorkspace(workspace)
                try command.validate(postcondition: postcondition)
            case .askUser(let prompt, let choices):
                try ExecutableAction.requireText(prompt)
                try choices.forEach(ExecutableAction.requireText)
                guard Set(choices).count == choices.count, postcondition == .answered else {
                    throw ExecutablePlanError.invalid("question requires unique choices and an answer")
                }
            }
        }
    }

    public struct WindowIdentity: Codable, Equatable, Sendable {
        public let bundleID: String
        public let processID: Int32
        public let windowID: UInt32
        public let connectionGeneration: UInt64

        public init(bundleID: String, processID: Int32, windowID: UInt32, connectionGeneration: UInt64) {
            self.bundleID = bundleID
            self.processID = processID
            self.windowID = windowID
            self.connectionGeneration = connectionGeneration
        }

        fileprivate func validate() throws {
            try ExecutableAction.requireText(bundleID)
            // Generation 0 is a real first connection, not "unset"; dispatch
            // re-checks the whole identity against the live target.
            guard processID > 0, windowID > 0 else {
                throw ExecutablePlanError.invalid("window requires exact live identity")
            }
        }
    }

    public enum Selector: Codable, Equatable, Sendable {
        case accessibilityID(String)
        case windowPixels(x: Double, y: Double)

        fileprivate func validate() throws {
            switch self {
            case .accessibilityID(let identifier): try ExecutableAction.requireText(identifier)
            case .windowPixels(let x, let y):
                guard x.isFinite, y.isFinite, x >= 0, y >= 0 else {
                    throw ExecutablePlanError.invalid("window coordinates must be finite and nonnegative")
                }
            }
        }
    }

    public enum ComputerCommand: Codable, Equatable, Sendable {
        case click(Selector)
        case rightClick(Selector)
        case doubleClick(Selector)
        case typeText(String, target: Selector)
        case scroll(direction: Direction, amount: Int, unit: ScrollUnit, target: Selector?)
        case pressKey(String, modifiers: [KeyModifier], target: Selector?)
        case hotkey(key: String, modifiers: [KeyModifier], target: Selector?)
        case drag(from: Selector, to: Selector, durationMilliseconds: Int, steps: Int)

        public enum Direction: String, Codable, Sendable { case up, down, left, right }
        public enum ScrollUnit: String, Codable, Sendable { case line, page }
        public enum KeyModifier: String, Codable, Sendable { case command, shift, option, control, function }

        fileprivate func validate() throws {
            switch self {
            case .click(let target), .rightClick(let target), .doubleClick(let target):
                try target.validate()
            case .typeText(let text, let target):
                guard !text.isEmpty else { throw ExecutablePlanError.invalid("typed text is empty") }
                try target.validate()
            case .scroll(_, let amount, _, let target):
                guard (1...50).contains(amount) else { throw ExecutablePlanError.invalid("scroll amount is invalid") }
                try target?.validate()
            case .pressKey(let key, let modifiers, let target):
                try Self.validateKey(key, modifiers: modifiers)
                try target?.validate()
            case .hotkey(let key, let modifiers, let target):
                guard !modifiers.isEmpty else { throw ExecutablePlanError.invalid("hotkey requires modifiers") }
                try Self.validateKey(key, modifiers: modifiers)
                try target?.validate()
            case .drag(let from, let to, let duration, let steps):
                guard (0...10_000).contains(duration), (1...200).contains(steps) else {
                    throw ExecutablePlanError.invalid("drag duration or steps are invalid")
                }
                try from.validate()
                try to.validate()
            }
        }

        private static func validateKey(_ key: String, modifiers: [KeyModifier]) throws {
            let normalized = key.lowercased()
            let named = ["return", "tab", "escape", "up", "down", "left", "right", "space", "delete", "home", "end", "pageup", "pagedown"]
            let character = normalized.count == 1 && (normalized.first?.isLetter == true || normalized.first?.isNumber == true)
            let functionKey = normalized.first == "f" && (1...12).contains(Int(normalized.dropFirst()) ?? 0)
            guard named.contains(normalized) || character || functionKey,
                  Set(modifiers.map(\.rawValue)).count == modifiers.count else {
                throw ExecutablePlanError.invalid("unsupported key or duplicate modifier")
            }
        }
    }

    public enum IntegrationCommand: Codable, Equatable, Sendable {
        case slackSendMessage(channelID: String, text: String)
        case notionCreatePage(parentID: String, title: String)
        case notionUpdatePage(pageID: String, title: String)
        case notionAppendBlock(blockID: String, text: String)
        case linearUpdateIssue(issueID: String, title: String)

        fileprivate func validate() throws {
            let identifier: String
            let text: String
            switch self {
            case .slackSendMessage(let id, let value), .notionCreatePage(let id, let value),
                 .notionUpdatePage(let id, let value), .notionAppendBlock(let id, let value),
                 .linearUpdateIssue(let id, let value):
                identifier = id
                text = value
            }
            try ExecutableAction.requireText(identifier)
            try ExecutableAction.requireText(text)
        }
    }

    public struct ExecutableIdentity: Codable, Equatable, Sendable {
        public let path: URL
        public let version: String
        public let sha256: String

        public init(path: URL, version: String, sha256: String) {
            self.path = path
            self.version = version
            self.sha256 = sha256
        }

        fileprivate func validate() throws {
            try ExecutableAction.requireWorkspace(path)
            try ExecutableAction.requireText(version)
            try ExecutableAction.requireDigest(sha256)
        }
    }

    public enum SandboxedCommand: Codable, Equatable, Sendable {
        case registeredCommand(arguments: [String])
        case codingTask(runtimeID: String, prompt: String)
    }

    public enum SandboxConfinement: String, Codable, Sendable {
        case workspaceReadOnly
        case workspaceReadWrite
    }

    public enum FileTransform: Codable, Equatable, Sendable {
        case createUTF8File(path: String, contents: String)
        case createDirectory(path: String)
        case rename(path: String, destination: String)
        case moveToTrash(path: String)

        fileprivate func validate(postcondition: Postcondition) throws {
            switch (self, postcondition) {
            case (.createUTF8File(let path, let contents), .fileContents(let expected)):
                try ExecutableAction.requireRelativePath(path)
                guard Array(contents.utf8) == Array(expected.utf8) else {
                    throw ExecutablePlanError.invalid("file postcondition differs from requested bytes")
                }
            case (.createDirectory(let path), .directoryExists):
                try ExecutableAction.requireRelativePath(path)
            case (.rename(let path, let destination), .renamedItem(let device, let inode)):
                try ExecutableAction.requireRelativePath(path)
                try ExecutableAction.requireRelativePath(destination)
                guard path != destination, device > 0, inode > 0 else {
                    throw ExecutablePlanError.invalid("rename requires distinct paths and source identity")
                }
            case (.moveToTrash(let path), .trashedItem(let device, let inode)):
                try ExecutableAction.requireRelativePath(path)
                guard device > 0, inode > 0 else { throw ExecutablePlanError.invalid("trash requires source identity") }
            default: throw ExecutablePlanError.invalid("file operation and postcondition do not match")
            }
        }
    }

    public enum Postcondition: Codable, Equatable, Sendable {
        case fileContents(String)
        case directoryExists
        case renamedItem(device: UInt64, inode: UInt64)
        case trashedItem(device: UInt64, inode: UInt64)
        case elementValue(String)
        case visualChange(baselineSHA256: String)
        case integrationResource(identifier: String, expectedText: String)
        case workspaceFileContents(path: String, contents: String)
        case answered
    }

    private static func requireText(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !value.contains("\0") else {
            throw ExecutablePlanError.invalid("required text is empty or contains NUL")
        }
    }

    static func requireRelativePath(_ path: String) throws {
        try requireText(path)
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"), components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ExecutablePlanError.invalid("workspace path must be relative without traversal")
        }
    }

    private static func requireWorkspace(_ url: URL) throws {
        guard url.isFileURL, url.baseURL == nil, url.path.hasPrefix("/"),
              url.host == nil || url.host == "" || url.host == "localhost",
              !url.path.contains("\0") else {
            throw ExecutablePlanError.invalid("workspace or executable URL must be an absolute local file URL")
        }
    }

    private static func requireDigest(_ value: String) throws {
        guard value.utf8.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ExecutablePlanError.invalid("expected a lowercase SHA-256 digest")
        }
    }
}
