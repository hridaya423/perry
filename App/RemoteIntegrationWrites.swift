import Foundation
import PerryBrain
import PerryCore
import PerryGuide
import PerryRuntimes

enum RemoteIntegrationWriteOperation: String, CaseIterable, Equatable, Hashable, Sendable {
    case notionCreatePage = "notion.createPage"
    case notionUpdatePage = "notion.updatePage"
    case notionAppendBlock = "notion.appendBlock"
    case slackSendMessage = "slack.sendMessage"
    case linearUpdateIssue = "linear.updateIssue"

    var providerID: String {
        switch self {
        case .notionCreatePage, .notionUpdatePage, .notionAppendBlock: "notion"
        case .slackSendMessage: "slack"
        case .linearUpdateIssue: "linear"
        }
    }

    var requiredScopes: Set<String> {
        switch self {
        case .notionCreatePage, .notionUpdatePage, .notionAppendBlock: []
        case .slackSendMessage: ["chat:write"]
        case .linearUpdateIssue: ["write"]
        }
    }
}

enum RemoteIntegrationWriteParameters: Equatable, Sendable {
    case notionCreatePage(parentID: String, title: String)
    case notionUpdatePage(pageID: String, title: String)
    case notionAppendBlock(blockID: String, text: String)
    case slackSendMessage(channel: String, text: String)
    case linearUpdateIssue(issueID: String, title: String)

    var operation: RemoteIntegrationWriteOperation {
        switch self {
        case .notionCreatePage: .notionCreatePage
        case .notionUpdatePage: .notionUpdatePage
        case .notionAppendBlock: .notionAppendBlock
        case .slackSendMessage: .slackSendMessage
        case .linearUpdateIssue: .linearUpdateIssue
        }
    }

    var method: String {
        switch self {
        case .notionCreatePage, .slackSendMessage, .linearUpdateIssue: "POST"
        case .notionUpdatePage, .notionAppendBlock: "PATCH"
        }
    }

    var path: String {
        switch self {
        case .notionCreatePage: "/v1/pages"
        case .notionUpdatePage(let pageID, _): "/v1/pages/\(pageID)"
        case .notionAppendBlock(let blockID, _): "/v1/blocks/\(blockID)/children"
        case .slackSendMessage: "/chat.postMessage"
        case .linearUpdateIssue: "/graphql"
        }
    }

    var isValid: Bool {
        switch self {
        case .notionCreatePage(let id, let text), .notionUpdatePage(let id, let text),
             .notionAppendBlock(let id, let text), .linearUpdateIssue(let id, let text):
            Self.validIdentifier(id) && Self.validText(text)
        case .slackSendMessage(let channel, let text):
            Self.validText(channel) && Self.validText(text)
        }
    }

    var body: JSONValue {
        switch self {
        case .notionCreatePage(let parentID, let title):
            .object(["parent": .object(["page_id": .string(parentID)]), "properties": Self.notionTitle(title)])
        case .notionUpdatePage(_, let title):
            .object(["properties": Self.notionTitle(title)])
        case .notionAppendBlock(_, let text):
            .object(["children": .array([.object([
                "object": .string("block"),
                "type": .string("paragraph"),
                "paragraph": .object(["rich_text": .array([.object([
                    "type": .string("text"),
                    "text": .object(["content": .string(text)]),
                ])])]),
            ])])])
        case .slackSendMessage(let channel, let text):
            .object(["channel": .string(channel), "text": .string(text)])
        case .linearUpdateIssue(let issueID, let title):
            .object([
                "query": .string("mutation UpdateIssue($issueId: String!, $title: String!) { issueUpdate(id: $issueId, input: { title: $title }) { success issue { id title } } }"),
                "variables": .object(["issueId": .string(issueID), "title": .string(title)]),
            ])
        }
    }

    private static func notionTitle(_ title: String) -> JSONValue {
        .object(["title": .object(["title": .array([.object(["text": .object(["content": .string(title)])])])])])
    }

    private static func validIdentifier(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    private static func validText(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !value.contains("\u{0000}")
    }
}

struct RemoteIntegrationWriteRequest: Equatable, Sendable {
    let parameters: RemoteIntegrationWriteParameters
    let body: Data

    init?(parameters: RemoteIntegrationWriteParameters) {
        guard parameters.isValid, let body = try? parameters.body.data() else { return nil }
        self.parameters = parameters
        self.body = body
    }

    var operation: RemoteIntegrationWriteOperation { parameters.operation }
    var method: String { parameters.method }
    var path: String { parameters.path }
    var requiredScopes: Set<String> { operation.requiredScopes }
}

struct RemoteIntegrationApproval: Equatable, Sendable {
    let stepID: String
    let integrationID: String
    let operation: RemoteIntegrationWriteOperation
    let tier: TrustTier
    let approvedScopes: Set<String>
    let request: RemoteIntegrationWriteRequest

    func matches(
        stepID: String?,
        definition: RemoteIntegrationDefinition,
        request: RemoteIntegrationWriteRequest
    ) -> Bool {
        guard tier >= .orange,
              integrationID == definition.id,
              operation == request.operation,
              self.request == request else {
            return false
        }
        if let stepID {
            guard self.stepID == stepID else { return false }
        } else {
            guard !self.stepID.isEmpty else { return false }
        }
        return request.requiredScopes.isSubset(of: approvedScopes)
    }
}

struct RemoteIntegrationActionRuntime {
    let client: RemoteIntegrationClient
    let definitions: [String: RemoteIntegrationDefinition]
    let permissionStore: RemoteIntegrationPermissionStore

    init(
        client: RemoteIntegrationClient,
        definitions: [RemoteIntegrationDefinition] = RemoteIntegrationDefinition.catalog,
        permissionStore: RemoteIntegrationPermissionStore = RemoteIntegrationPermissionStore()
    ) {
        self.client = client
        self.definitions = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })
        self.permissionStore = permissionStore
    }

    var executableAccountIDs: Set<String> {
        Set(definitions.values.filter { permissionStore.writesEnabled(for: $0) }.map(\.id))
    }

    func execute(approvedAction: ApprovedExecutableAction) async throws -> ActionExecutionResult {
        let action = approvedAction.action
        guard case .integration(let accountID, let command) = action.operation else {
            throw RemoteIntegrationError.malformedRequest
        }
        guard let definition = definitions[accountID] else {
            throw RemoteIntegrationError.missingIntegration
        }
        let parameters: RemoteIntegrationWriteParameters
        switch command {
        case .slackSendMessage(let channelID, let text):
            parameters = .slackSendMessage(channel: channelID, text: text)
        case .notionCreatePage(let parentID, let title):
            parameters = .notionCreatePage(parentID: parentID, title: title)
        case .notionUpdatePage(let pageID, let title):
            parameters = .notionUpdatePage(pageID: pageID, title: title)
        case .notionAppendBlock(let blockID, let text):
            parameters = .notionAppendBlock(blockID: blockID, text: text)
        case .linearUpdateIssue(let issueID, let title):
            parameters = .linearUpdateIssue(issueID: issueID, title: title)
        }
        guard let write = RemoteIntegrationWriteRequest(parameters: parameters) else {
            throw RemoteIntegrationError.malformedRequest
        }
        let approval = RemoteIntegrationApproval(
            stepID: action.id.rawValue,
            integrationID: definition.id,
            operation: write.operation,
            tier: action.policy.trustTier,
            approvedScopes: write.requiredScopes,
            request: write
        )
        let response = try await client.request(definition: definition, write: write, approval: approval)
        return ActionExecutionResult(action: action, evidence: .integrationResponse(response))
    }
}
