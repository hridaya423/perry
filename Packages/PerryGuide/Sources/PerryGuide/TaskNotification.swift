import Foundation

public struct TaskNotification: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case completed
        case stopped
        case needsConfirmation
    }

    public let kind: Kind
    public let title: String
    public let body: String
    public let taskID: TaskID?
    public let actionID: String?
    public let taskRevision: UUID?

    public init(
        kind: TaskNotification.Kind,
        title: String,
        body: String,
        taskID: TaskID? = nil,
        actionID: String? = nil,
        taskRevision: UUID? = nil
    ) {
        self.kind = kind
        self.title = title
        self.body = body
        self.taskID = taskID
        self.actionID = actionID
        self.taskRevision = taskRevision
    }
}

public protocol Notifying: Sendable {
    func deliver(_ notification: TaskNotification) async
}
