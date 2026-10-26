import AuthenticationServices
import CryptoKit
import Foundation
import PerryBrain
import PerryCore
import PerryGuide
import PerryRuntimes

enum OAuthClientAuthStyle: String, Sendable {
    case basicSecret
    case formSecret
    case pkce

    var supportsPKCE: Bool {
        self == .pkce
    }

    var requiresClientSecret: Bool {
        self == .basicSecret || self == .formSecret
    }
}

enum RemoteIntegrationWriteOperation: String, CaseIterable, Equatable, Hashable, Sendable {
    case notionCreatePage = "notion.createPage"
    case notionUpdatePage = "notion.updatePage"
    case notionAppendBlock = "notion.appendBlock"
    case slackSendMessage = "slack.sendMessage"
    case linearUpdateIssue = "linear.updateIssue"

    init?(identifier: String) {
        let normalized = identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ".", with: "")
        switch normalized {
        case "notioncreatepage": self = .notionCreatePage
        case "notionupdatepage": self = .notionUpdatePage
        case "notionappendblock": self = .notionAppendBlock
        case "slacksendmessage", "slackchatpostmessage": self = .slackSendMessage
        case "linearupdateissue", "linearissueupdate": self = .linearUpdateIssue
        default: return nil
        }
    }

    var providerID: String {
        switch self {
        case .notionCreatePage, .notionUpdatePage, .notionAppendBlock:
            return "notion"
        case .slackSendMessage:
            return "slack"
        case .linearUpdateIssue:
            return "linear"
        }
    }

    var requiredScopes: Set<String> {
        switch self {
        case .notionCreatePage, .notionUpdatePage, .notionAppendBlock:
            return []
        case .slackSendMessage:
            return ["chat:write"]
        case .linearUpdateIssue:
            return ["write"]
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
        case .notionCreatePage: return .notionCreatePage
        case .notionUpdatePage: return .notionUpdatePage
        case .notionAppendBlock: return .notionAppendBlock
        case .slackSendMessage: return .slackSendMessage
        case .linearUpdateIssue: return .linearUpdateIssue
        }
    }

    var method: String {
        switch self {
        case .notionCreatePage, .slackSendMessage, .linearUpdateIssue:
            return "POST"
        case .notionUpdatePage, .notionAppendBlock:
            return "PATCH"
        }
    }

    var path: String {
        switch self {
        case .notionCreatePage:
            return "/v1/pages"
        case .notionUpdatePage(let pageID, _):
            return "/v1/pages/\(pageID)"
        case .notionAppendBlock(let blockID, _):
            return "/v1/blocks/\(blockID)/children"
        case .slackSendMessage:
            return "/chat.postMessage"
        case .linearUpdateIssue:
            return "/graphql"
        }
    }

    var requiredScopes: Set<String> {
        operation.requiredScopes
    }

    var isValid: Bool {
        switch self {
        case .notionCreatePage(let parentID, let title):
            return Self.validIdentifier(parentID) && Self.validText(title)
        case .notionUpdatePage(let pageID, let title):
            return Self.validIdentifier(pageID) && Self.validText(title)
        case .notionAppendBlock(let blockID, let text):
            return Self.validIdentifier(blockID) && Self.validText(text)
        case .slackSendMessage(let channel, let text):
            return Self.validText(channel) && Self.validText(text)
        case .linearUpdateIssue(let issueID, let title):
            return Self.validIdentifier(issueID) && Self.validText(title)
        }
    }

    var body: Data? {
        guard isValid else { return nil }
        switch self {
        case .notionCreatePage(let parentID, let title):
            return Self.jsonData([
                "parent": ["page_id": parentID],
                "properties": [
                    "title": [
                        "title": [["text": ["content": title]]],
                    ],
                ],
            ])
        case .notionUpdatePage(_, let title):
            return Self.jsonData([
                "properties": [
                    "title": [
                        "title": [["text": ["content": title]]],
                    ],
                ],
            ])
        case .notionAppendBlock(_, let text):
            return Self.jsonData([
                "children": [[
                    "object": "block",
                    "type": "paragraph",
                    "paragraph": [
                        "rich_text": [["type": "text", "text": ["content": text]]],
                    ],
                ]],
            ])
        case .slackSendMessage(let channel, let text):
            return Self.jsonData(["channel": channel, "text": text])
        case .linearUpdateIssue(let issueID, let title):
            let query = "mutation UpdateIssue($issueId: String!, $title: String!) { issueUpdate(id: $issueId, input: { title: $title }) { success issue { id title } } }"
            return Self.jsonData([
                "query": query,
                "variables": ["issueId": issueID, "title": title],
            ])
        }
    }

    private static func validIdentifier(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.allSatisfy { character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
        }
    }

    private static func validText(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !value.contains("\u{0000}")
    }

    private static func jsonData(_ object: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

struct RemoteIntegrationWriteRequest: Equatable, Sendable {
    let parameters: RemoteIntegrationWriteParameters

    init?(parameters: RemoteIntegrationWriteParameters) {
        guard parameters.isValid, parameters.body != nil else { return nil }
        self.parameters = parameters
    }

    var operation: RemoteIntegrationWriteOperation { parameters.operation }
    var method: String { parameters.method }
    var path: String { parameters.path }
    var body: Data { parameters.body! }
    var requiredScopes: Set<String> { parameters.requiredScopes }
}

struct RemoteIntegrationApproval: Equatable, Sendable {
    let stepID: String
    let integrationID: String
    let operation: RemoteIntegrationWriteOperation
    let tier: TrustTier
    let approvedScopes: Set<String>
    let request: RemoteIntegrationWriteRequest

    init(
        stepID: String,
        integrationID: String,
        operation: RemoteIntegrationWriteOperation,
        tier: TrustTier,
        approvedScopes: Set<String>,
        request: RemoteIntegrationWriteRequest
    ) {
        self.stepID = stepID
        self.integrationID = integrationID
        self.operation = operation
        self.tier = tier
        self.approvedScopes = approvedScopes
        self.request = request
    }

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

struct RemoteIntegrationQuickAction: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let method: String
    let path: String
    let body: String?
    let readOnly: Bool

    init(
        id: String,
        title: String,
        method: String,
        path: String,
        body: String? = nil,
        readOnly: Bool = true
    ) {
        self.id = id
        self.title = title
        self.method = method
        self.path = path
        self.body = body
        self.readOnly = readOnly
    }

    var bodyData: Data? {
        body.map { Data($0.utf8) }
    }
}

struct RemoteIntegrationDefinition: Identifiable, Equatable, Sendable {
    let descriptor: IntegrationDescriptor
    let baseURL: URL
    let authorizationURL: URL
    let tokenURL: URL
    let scopes: [String]
    let writesEnabledByDefault: Bool
    let oauthStyle: OAuthClientAuthStyle
    let authorizationParameters: [String: String]
    var redirectKind: OAuthRedirectKind = .customScheme
    var writeScopes: [String] = []
    var bundledClientKeys: BundledClientKeys?
    var deviceAuthorizationURL: URL?
    var revocation: OAuthRevocation?

    private enum Provider: Equatable {
        case notion
        case slack
        case linear
        case github
        case googleWorkspace

        init?(id: String) {
            switch id {
            case "notion": self = .notion
            case "slack": self = .slack
            case "linear": self = .linear
            case "github": self = .github
            case "google-workspace": self = .googleWorkspace
            default: return nil
            }
        }
    }

    private enum GraphQLOperation: Equatable {
        case query
        case mutation
        case subscription
    }

    private enum GraphQLToken {
        case name(String)
        case openBrace
        case closeBrace
        case openParen
        case closeParen
        case openBracket
        case closeBracket
        case other
    }

    private static let rejectedQueryFragments = [
        "accesstoken",
        "clientid",
        "clientsecret",
        "code",
        "cookie",
        "credential",
        "key",
        "password",
        "redirecturi",
        "refreshtoken",
        "secret",
        "state",
        "token",
    ]

    var id: String { descriptor.id }
    var displayName: String { descriptor.displayName }
    var credentialAccount: String {
        descriptor.credentialReference?.account ?? "integration.\(descriptor.id)"
    }
    var requiresClientSecret: Bool {
        oauthStyle.requiresClientSecret
    }
    var authorizationScopeParameter: String {
        id == "slack" && oauthStyle.supportsPKCE ? "user_scope" : "scope"
    }
    var authorizationScopeSeparator: String {
        id == "slack" || id == "linear" ? "," : " "
    }
    var redirectInstructions: String {
        switch redirectKind {
        case .customScheme:
            return "Add this callback URL in the provider’s developer settings, then enter its credentials."
        case .loopback:
            return "Create a desktop-app client with a loopback redirect (http://127.0.0.1, any port), then enter its credentials."
        case .deviceFlow:
            return "Enable device flow in the provider’s developer settings, then enter the client ID. No callback URL is needed."
        }
    }
    var showsCallbackURL: Bool {
        redirectKind == .customScheme
    }
    var allowsReadOnlyPost: Bool {
        id == "notion" || id == "linear"
    }
    func authorizationHeader(for token: OAuthToken) -> String {
        let tokenType = id == "slack" ? "Bearer" : token.tokenType
        return "\(tokenType) \(token.accessToken)"
    }
    var defaultHeaders: [String: String] {
        switch id {
        case "notion":
            return ["Notion-Version": "2026-03-11"]
        case "github":
            return ["Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"]
        default:
            return [:]
        }
    }
    var testPath: String {
        switch id {
        case "notion": return "/v1/users/me"
        case "slack": return "/auth.test"
        case "linear": return "/graphql"
        case "github": return "/user"
        case "google-workspace": return "/drive/v3/about?fields=user(displayName,emailAddress)"
        default: return "/"
        }
    }
    var testMethod: String {
        id == "linear" ? "POST" : "GET"
    }
    var testBody: Data? {
        guard id == "linear" else { return nil }
        return Data("{\"query\":\"query { viewer { id name email } }\"}".utf8)
    }
    var connectionHint: String {
        switch id {
        case "google-workspace": return "Gmail, Calendar, Drive, Docs, and Sheets read access"
        case "notion": return "Pages, databases, and workspace search"
        case "slack": return "Workspace and channel access"
        case "linear": return "Issues, teams, and workspace metadata"
        case "github": return "Your profile, notifications, and assigned issues"
        default: return "Provider API access"
        }
    }

    func requireSafeEndpoints() throws {
        try NetworkEndpointPolicy.requireSafe(baseURL)
        try NetworkEndpointPolicy.requireSafe(authorizationURL)
        try NetworkEndpointPolicy.requireSafe(tokenURL)
        if let deviceAuthorizationURL {
            try NetworkEndpointPolicy.requireSafe(deviceAuthorizationURL)
        }
        if let revocation {
            try NetworkEndpointPolicy.requireSafe(revocation.url)
        }
    }

    var allowedReadPathPrefixes: [String] {
        switch id {
        case "notion":
            return ["/v1/users/me", "/v1/search", "/v1/pages", "/v1/databases", "/v1/data_sources", "/v1/blocks"]
        case "slack":
            return ["/auth.test", "/conversations.list", "/conversations.history", "/conversations.replies", "/users.list", "/team.info"]
        case "linear":
            return ["/graphql"]
        case "github":
            return ["/user", "/notifications", "/issues"]
        case "google-workspace":
            return ["/drive/v3", "/gmail/v1", "/calendar/v3", "/docs/v1", "/sheets/v4", "/oauth2/v3/userinfo"]
        default:
            return []
        }
    }

    var allowedWritePathPrefixes: [String] {
        switch id {
        case "notion":
            return ["/v1/pages", "/v1/blocks"]
        case "slack":
            return ["/chat.postMessage"]
        case "linear":
            return ["/graphql"]
        default:
            return []
        }
    }

    var allowedWriteOperations: [RemoteIntegrationWriteOperation] {
        switch id {
        case "notion":
            return [.notionCreatePage, .notionUpdatePage, .notionAppendBlock]
        case "slack":
            return [.slackSendMessage]
        case "linear":
            return [.linearUpdateIssue]
        default:
            return []
        }
    }

    func allowsRemoteWrite(_ request: RemoteIntegrationWriteRequest) -> Bool {
        guard request.operation.providerID == id,
              allowedWriteOperations.contains(request.operation) else {
            return false
        }
        return allowsRemoteRequest(
            path: request.path,
            method: request.method,
            body: request.body,
            readOnlyRequest: false
        )
    }

    var quickActions: [RemoteIntegrationQuickAction] {
        switch id {
        case "notion":
            return [
                RemoteIntegrationQuickAction(
                    id: "search",
                    title: "Search pages",
                    method: "POST",
                    path: "/v1/search",
                    body: #"{"page_size":10}"#
                ),
            ]
        case "slack":
            return [
                RemoteIntegrationQuickAction(
                    id: "channels",
                    title: "List channels",
                    method: "GET",
                    path: "/conversations.list?limit=20&exclude_archived=true"
                ),
                RemoteIntegrationQuickAction(
                    id: "team",
                    title: "Read workspace",
                    method: "GET",
                    path: "/team.info"
                ),
            ]
        case "linear":
            return [
                RemoteIntegrationQuickAction(
                    id: "issues",
                    title: "Read recent issues",
                    method: "POST",
                    path: "/graphql",
                    body: #"{"query":"query { issues(first: 10, orderBy: updatedAt) { nodes { identifier title url state { name } } } }"}"#
                ),
            ]
        case "github":
            return [
                RemoteIntegrationQuickAction(
                    id: "profile",
                    title: "Read your profile",
                    method: "GET",
                    path: "/user"
                ),
                RemoteIntegrationQuickAction(
                    id: "notifications",
                    title: "Read recent notifications",
                    method: "GET",
                    path: "/notifications?per_page=10"
                ),
                RemoteIntegrationQuickAction(
                    id: "issues",
                    title: "Read issues assigned to you",
                    method: "GET",
                    path: "/issues?filter=assigned&per_page=10"
                ),
            ]
        case "google-workspace":
            return [
                RemoteIntegrationQuickAction(
                    id: "drive",
                    title: "Read recent Drive files",
                    method: "GET",
                    path: "/drive/v3/files?pageSize=10&orderBy=modifiedTime%20desc&fields=files(id,name,mimeType,modifiedTime)"
                ),
                RemoteIntegrationQuickAction(
                    id: "gmail",
                    title: "Read recent Gmail messages",
                    method: "GET",
                    path: "/gmail/v1/users/me/messages?maxResults=10"
                ),
            ]
        default:
            return []
        }
    }

    func allowsRemoteRequest(path: String, method: String, body: Data?, readOnlyRequest: Bool) -> Bool {
        guard (try? requireSafeEndpoints()) != nil,
              let provider = Provider(id: id),
              let components = URLComponents(string: path),
              components.scheme == nil,
              components.host == nil,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.path.hasPrefix("/"),
              Self.hasSafeQuery(components),
              !components.path.contains(".."),
              !components.path.contains("\\"),
              !components.path.isEmpty else { return false }
        let requestPath = components.path
        let normalizedMethod = method.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalizedMethod.isEmpty else { return false }
        let isReadMethod = normalizedMethod == "GET"
            || normalizedMethod == "HEAD"
            || (readOnlyRequest && normalizedMethod == "POST" && allowsReadOnlyPost)
        if readOnlyRequest && !isReadMethod {
            return false
        }
        if isReadMethod {
            if (normalizedMethod == "GET" || normalizedMethod == "HEAD") && body != nil {
                return false
            }
            guard allowedReadPathPrefixes.contains(where: { requestPath == $0 || requestPath.hasPrefix($0 + "/") }) else {
                return false
            }
            if normalizedMethod == "POST" {
                guard Self.isJSONObject(body) else { return false }
                if provider == .notion && requestPath != "/v1/search" {
                    return false
                }
                if provider == .linear {
                    return Self.graphQLIsReadOnly(body)
                }
            }
            return true
        }
        guard allowedWritePathPrefixes.contains(where: { requestPath == $0 || requestPath.hasPrefix($0 + "/") }) else {
            return false
        }
        guard Self.isJSONObject(body) else { return false }
        switch provider {
        case .notion:
            guard normalizedMethod == "POST" || normalizedMethod == "PATCH" else { return false }
        case .slack:
            guard normalizedMethod == "POST" else { return false }
        case .linear:
            guard normalizedMethod == "POST" else { return false }
            return Self.graphQLIsMutation(body)
        case .github, .googleWorkspace:
            return false
        }
        return true
    }

    private static func isJSONObject(_ body: Data?) -> Bool {
        guard let body,
              let object = try? JSONSerialization.jsonObject(with: body) else {
            return false
        }
        return JSONSerialization.isValidJSONObject(object)
    }

    private static func hasSafeQuery(_ components: URLComponents) -> Bool {
        guard let queryItems = components.queryItems else {
            return components.percentEncodedQuery == nil
        }
        return queryItems.allSatisfy { item in
            let normalizedName = item.name.lowercased().filter { $0.isLetter || $0.isNumber }
            return !rejectedQueryFragments.contains { normalizedName.contains($0) }
        }
    }

    private static func graphQLIsReadOnly(_ body: Data?) -> Bool {
        graphQLOperation(body) == .query
    }

    private static func graphQLIsMutation(_ body: Data?) -> Bool {
        graphQLOperation(body) == .mutation
    }

    private static func graphQLOperation(_ body: Data?) -> GraphQLOperation? {
        guard let body,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let query = object["query"] as? String,
              let tokens = graphQLTokens(query) else {
            return nil
        }

        var operations: [GraphQLOperation] = []
        var delimiters: [Character] = []
        var braceHasContent: [Bool] = []
        var pendingOperation: GraphQLOperation?
        var pendingFragment = false

        for token in tokens {
            switch token {
            case .openBrace:
                if !braceHasContent.isEmpty {
                    braceHasContent[braceHasContent.count - 1] = true
                }
                if delimiters.isEmpty {
                    if let operation = pendingOperation {
                        operations.append(operation)
                        pendingOperation = nil
                    } else if !pendingFragment {
                        operations.append(.query)
                    }
                    pendingFragment = false
                }
                delimiters.append("{")
                braceHasContent.append(false)
            case .closeBrace:
                guard delimiters.last == "{",
                      braceHasContent.popLast() == true else { return nil }
                delimiters.removeLast()
            case .openParen:
                if !braceHasContent.isEmpty {
                    braceHasContent[braceHasContent.count - 1] = true
                }
                delimiters.append("(")
            case .closeParen:
                guard delimiters.last == "(" else { return nil }
                delimiters.removeLast()
            case .openBracket:
                if !braceHasContent.isEmpty {
                    braceHasContent[braceHasContent.count - 1] = true
                }
                delimiters.append("[")
            case .closeBracket:
                guard delimiters.last == "[" else { return nil }
                delimiters.removeLast()
            case .name(let name):
                if !braceHasContent.isEmpty {
                    braceHasContent[braceHasContent.count - 1] = true
                }
                guard delimiters.isEmpty else { continue }
                if pendingOperation != nil || pendingFragment {
                    continue
                }
                switch name {
                case "query":
                    guard operations.isEmpty else { return nil }
                    pendingOperation = .query
                case "mutation":
                    guard operations.isEmpty else { return nil }
                    pendingOperation = .mutation
                case "subscription":
                    guard operations.isEmpty else { return nil }
                    pendingOperation = .subscription
                case "fragment":
                    pendingFragment = true
                default:
                    return nil
                }
            case .other:
                if !braceHasContent.isEmpty {
                    braceHasContent[braceHasContent.count - 1] = true
                }
                guard !delimiters.isEmpty || pendingOperation != nil || pendingFragment else {
                    return nil
                }
            }
        }

        guard delimiters.isEmpty,
              braceHasContent.isEmpty,
              pendingOperation == nil,
              !pendingFragment,
              operations.count == 1 else {
            return nil
        }
        return operations[0]
    }

    private static func graphQLTokens(_ query: String) -> [GraphQLToken]? {
        let characters = Array(query)
        var tokens: [GraphQLToken] = []
        var index = 0

        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace || character == "," {
                index += 1
                continue
            }
            if character == "#" {
                while index < characters.count && characters[index] != "\n" {
                    index += 1
                }
                continue
            }
            if character == "\"" {
                let isBlockString = index + 2 < characters.count
                    && characters[index + 1] == "\""
                    && characters[index + 2] == "\""
                index += isBlockString ? 3 : 1
                var closed = false
                while index < characters.count {
                    if isBlockString {
                        if index + 2 < characters.count,
                           characters[index] == "\"",
                           characters[index + 1] == "\"",
                           characters[index + 2] == "\"" {
                            index += 3
                            closed = true
                            break
                        }
                        index += 1
                    } else {
                        let current = characters[index]
                        index += 1
                        if current == "\\" {
                            guard index < characters.count else { return nil }
                            index += 1
                        } else if current == "\"" {
                            closed = true
                            break
                        }
                    }
                }
                guard closed else { return nil }
                continue
            }
            if character == "{" {
                tokens.append(.openBrace)
                index += 1
                continue
            }
            if character == "}" {
                tokens.append(.closeBrace)
                index += 1
                continue
            }
            if character == "(" {
                tokens.append(.openParen)
                index += 1
                continue
            }
            if character == ")" {
                tokens.append(.closeParen)
                index += 1
                continue
            }
            if character == "[" {
                tokens.append(.openBracket)
                index += 1
                continue
            }
            if character == "]" {
                tokens.append(.closeBracket)
                index += 1
                continue
            }
            if character == "_" || character.isLetter {
                let start = index
                index += 1
                while index < characters.count {
                    let current = characters[index]
                    guard current == "_" || current.isLetter || current.isNumber else { break }
                    index += 1
                }
                tokens.append(.name(String(characters[start..<index])))
                continue
            }
            tokens.append(.other)
            index += 1
        }

        return tokens
    }

    static let catalog: [RemoteIntegrationDefinition] = [
        RemoteIntegrationDefinition(
            descriptor: IntegrationDescriptor(
                id: "notion",
                displayName: "Notion",
                credentialReference: CredentialReference(service: "dev.perry.integrations", account: "integration.notion")
            ),
            baseURL: URL(string: "https://api.notion.com")!,
            authorizationURL: URL(string: "https://api.notion.com/v1/oauth/authorize")!,
            tokenURL: URL(string: "https://api.notion.com/v1/oauth/token")!,
            scopes: [],
            writesEnabledByDefault: false,
            oauthStyle: .basicSecret,
            authorizationParameters: ["owner": "user"]
        ),
        RemoteIntegrationDefinition(
            descriptor: IntegrationDescriptor(
                id: "slack",
                displayName: "Slack",
                credentialReference: CredentialReference(service: "dev.perry.integrations", account: "integration.slack")
            ),
            baseURL: URL(string: "https://slack.com/api")!,
            authorizationURL: URL(string: "https://slack.com/oauth/v2/authorize")!,
            tokenURL: URL(string: "https://slack.com/api/oauth.v2.access")!,
            scopes: [
                "channels:read",
                "channels:history",
                "groups:read",
                "groups:history",
                "users:read",
                "team:read",
            ],
            writesEnabledByDefault: false,
            oauthStyle: .pkce,
            authorizationParameters: [:],
            redirectKind: .customScheme,
            writeScopes: ["chat:write"],
            bundledClientKeys: BundledClientKeys(clientIDKey: "PerryOAuthSlackClientID", clientSecretKey: nil),
            revocation: .bearerHeader(URL(string: "https://slack.com/api/auth.revoke")!)
        ),
        RemoteIntegrationDefinition(
            descriptor: IntegrationDescriptor(
                id: "linear",
                displayName: "Linear",
                credentialReference: CredentialReference(service: "dev.perry.integrations", account: "integration.linear")
            ),
            baseURL: URL(string: "https://api.linear.app")!,
            authorizationURL: URL(string: "https://linear.app/oauth/authorize")!,
            tokenURL: URL(string: "https://api.linear.app/oauth/token")!,
            scopes: ["read"],
            writesEnabledByDefault: false,
            oauthStyle: .pkce,
            authorizationParameters: [:],
            redirectKind: .customScheme,
            writeScopes: ["write"],
            bundledClientKeys: BundledClientKeys(clientIDKey: "PerryOAuthLinearClientID", clientSecretKey: nil),
            revocation: .tokenForm(URL(string: "https://api.linear.app/oauth/revoke")!, sendsTypeHint: true)
        ),
        RemoteIntegrationDefinition(
            descriptor: IntegrationDescriptor(
                id: "github",
                displayName: "GitHub",
                credentialReference: CredentialReference(service: "dev.perry.integrations", account: "integration.github")
            ),
            baseURL: URL(string: "https://api.github.com")!,
            authorizationURL: URL(string: "https://github.com/login/oauth/authorize")!,
            tokenURL: URL(string: "https://github.com/login/oauth/access_token")!,
            scopes: ["read:user", "notifications"],
            writesEnabledByDefault: false,
            oauthStyle: .pkce,
            authorizationParameters: [:],
            redirectKind: .deviceFlow,
            bundledClientKeys: BundledClientKeys(clientIDKey: "PerryOAuthGitHubClientID", clientSecretKey: nil),
            deviceAuthorizationURL: URL(string: "https://github.com/login/device/code")!
        ),
        RemoteIntegrationDefinition(
            descriptor: IntegrationDescriptor(
                id: "google-workspace",
                displayName: "Google Workspace",
                credentialReference: CredentialReference(service: "dev.perry.integrations", account: "integration.google-workspace")
            ),
            baseURL: URL(string: "https://www.googleapis.com")!,
            authorizationURL: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            tokenURL: URL(string: "https://oauth2.googleapis.com/token")!,
            scopes: [
                "openid",
                "email",
                "profile",
                "https://www.googleapis.com/auth/drive.readonly",
                "https://www.googleapis.com/auth/gmail.readonly",
                "https://www.googleapis.com/auth/calendar.readonly",
                "https://www.googleapis.com/auth/documents.readonly",
                "https://www.googleapis.com/auth/spreadsheets.readonly",
            ],
            writesEnabledByDefault: false,
            oauthStyle: .pkce,
            authorizationParameters: ["access_type": "offline", "prompt": "consent"]
        ),
    ]
}

struct RemoteIntegrationPermissionStore: Sendable {
    private let suiteName: String?

    init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    func writesEnabled(for definition: RemoteIntegrationDefinition) -> Bool {
        guard let stored = defaults().object(forKey: key(for: definition)) as? Bool else {
            return definition.writesEnabledByDefault
        }
        return stored
    }

    func setWritesEnabled(_ enabled: Bool, for definition: RemoteIntegrationDefinition) {
        defaults().set(enabled, forKey: key(for: definition))
    }

    private func defaults() -> UserDefaults {
        if let suiteName, let defaults = UserDefaults(suiteName: suiteName) {
            return defaults
        }
        return .standard
    }

    private func key(for definition: RemoteIntegrationDefinition) -> String {
        PerryPreferences.remoteWritesKey(for: definition.id)
    }
}

struct OAuthConfiguration: Sendable {
    static let defaultRedirectURI = URL(string: "dev.perry.perry:/oauth/callback")!

    let clientID: String
    let clientSecret: String?
    let redirectURI: URL
    let scopes: [String]

    init(
        clientID: String,
        clientSecret: String? = nil,
        redirectURI: URL = OAuthConfiguration.defaultRedirectURI,
        scopes: [String]
    ) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.redirectURI = redirectURI
        self.scopes = scopes
    }
}

struct OAuthToken: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let tokenType: String
    let expiresAt: Date?
    let scopes: Set<String>

    init(
        accessToken: String,
        refreshToken: String? = nil,
        tokenType: String = "Bearer",
        expiresAt: Date? = nil,
        scopes: Set<String> = []
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenType = tokenType
        self.expiresAt = expiresAt
        self.scopes = scopes
    }

    private enum CodingKeys: String, CodingKey {
        case accessToken
        case refreshToken
        case tokenType
        case expiresAt
        case scopes
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try values.decode(String.self, forKey: .accessToken)
        refreshToken = try values.decodeIfPresent(String.self, forKey: .refreshToken)
        tokenType = try values.decode(String.self, forKey: .tokenType)
        expiresAt = try values.decodeIfPresent(Date.self, forKey: .expiresAt)
        scopes = try values.decodeIfPresent(Set<String>.self, forKey: .scopes) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(accessToken, forKey: .accessToken)
        try values.encodeIfPresent(refreshToken, forKey: .refreshToken)
        try values.encode(tokenType, forKey: .tokenType)
        try values.encodeIfPresent(expiresAt, forKey: .expiresAt)
        try values.encode(scopes, forKey: .scopes)
    }

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }

    var needsRefresh: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date().addingTimeInterval(60)
    }
}

struct StoredOAuthCredential: Codable, Equatable, Sendable {
    let token: OAuthToken
    let clientID: String
    let clientSecret: String?
    let grantedScopes: Set<String>

    init(
        token: OAuthToken,
        clientID: String,
        clientSecret: String?,
        grantedScopes: Set<String>? = nil
    ) {
        self.token = token
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.grantedScopes = grantedScopes ?? token.scopes
    }

    private enum CodingKeys: String, CodingKey {
        case token
        case clientID
        case clientSecret
        case grantedScopes
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        token = try values.decode(OAuthToken.self, forKey: .token)
        clientID = try values.decode(String.self, forKey: .clientID)
        clientSecret = try values.decodeIfPresent(String.self, forKey: .clientSecret)
        grantedScopes = try values.decodeIfPresent(Set<String>.self, forKey: .grantedScopes) ?? token.scopes
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(token, forKey: .token)
        try values.encode(clientID, forKey: .clientID)
        try values.encodeIfPresent(clientSecret, forKey: .clientSecret)
        try values.encode(grantedScopes, forKey: .grantedScopes)
    }
}

protocol OAuthCredentialStoreBackend: Sendable {
    func readCredential(account: String) throws -> String?
    func save(_ secret: String, account: String) throws
    func deleteCredential(account: String) throws
}

extension KeychainStore: OAuthCredentialStoreBackend {
    func readCredential(account: String) throws -> String? {
        try readChecked(account: account)
    }

    func deleteCredential(account: String) throws {
        try deleteChecked(account: account)
    }
}

enum OAuthCredentialStoreError: Error, Equatable, LocalizedError {
    case keychainUnavailable(String)
    case malformedCredential(String)

    var errorDescription: String? {
        switch self {
        case .keychainUnavailable(let account):
            return "Perry could not read the saved credential for \(account). Check Keychain access and try again."
        case .malformedCredential(let account):
            return "The saved credential for \(account) is damaged. Disconnect and reconnect this integration."
        }
    }
}

actor OAuthCredentialStore {
    private let backend: any OAuthCredentialStoreBackend

    init(keychain: KeychainStore = KeychainStore(service: "dev.perry.integrations")) {
        backend = keychain
    }

    init(backend: any OAuthCredentialStoreBackend) {
        self.backend = backend
    }

    func load(for definition: RemoteIntegrationDefinition) throws -> StoredOAuthCredential? {
        let encoded: String?
        do {
            encoded = try backend.readCredential(account: definition.credentialAccount)
        } catch {
            throw OAuthCredentialStoreError.keychainUnavailable(definition.credentialAccount)
        }
        guard let encoded,
              let data = encoded.data(using: .utf8) else { return nil }
        do {
            let credential = try JSONDecoder().decode(StoredOAuthCredential.self, from: data)
            return credential
        } catch {
            do {
                let token = try JSONDecoder().decode(OAuthToken.self, from: data)
                return StoredOAuthCredential(token: token, clientID: "", clientSecret: nil)
            } catch {
                throw OAuthCredentialStoreError.malformedCredential(definition.credentialAccount)
            }
        }
    }

    func save(_ credential: StoredOAuthCredential, for definition: RemoteIntegrationDefinition) throws {
        let data = try JSONEncoder().encode(credential)
        try backend.save(String(decoding: data, as: UTF8.self), account: definition.credentialAccount)
    }

    func delete(for definition: RemoteIntegrationDefinition) throws {
        do {
            try backend.deleteCredential(account: definition.credentialAccount)
        } catch {
            throw OAuthCredentialStoreError.keychainUnavailable(definition.credentialAccount)
        }
    }
}

enum OAuthError: Error, LocalizedError {
    case invalidClient
    case invalidClientSecret
    case cancelled
    case invalidCallback
    case callbackMissingCode
    case providerReturned(String)
    case stateMismatch
    case tokenExchangeFailed(Int)
    case tokenResponseInvalid
    case refreshFailed(Int)
    case deviceCodeExpired

    var errorDescription: String? {
        switch self {
        case .invalidClient: return "OAuth client ID is missing."
        case .invalidClientSecret: return "This provider requires an OAuth client secret."
        case .cancelled: return "OAuth authorization was cancelled."
        case .invalidCallback: return "OAuth returned to an unexpected callback URL."
        case .callbackMissingCode: return "OAuth callback did not include an authorization code."
        case .providerReturned(let message): return message
        case .stateMismatch: return "OAuth state did not match the request."
        case .tokenExchangeFailed(let status): return "OAuth token exchange returned HTTP \(status)."
        case .tokenResponseInvalid: return "OAuth token response was invalid."
        case .refreshFailed(let status): return "OAuth token refresh returned HTTP \(status)."
        case .deviceCodeExpired: return "The sign-in code expired before it was approved. Try connecting again."
        }
    }
}

enum RemoteIntegrationError: Error, Equatable, LocalizedError {
    case missingIntegration
    case authenticationRequired
    case malformedRequest
    case capabilityDenied
    case scopeDenied
    case writesDisabled
    case providerReturned(String)

    var errorDescription: String? {
        switch self {
        case .missingIntegration:
            return "That remote integration is not available."
        case .authenticationRequired:
            return "Connect this remote integration again before asking Perry to use it."
        case .malformedRequest:
            return "The remote integration request was incomplete."
        case .capabilityDenied:
            return "Perry blocked that remote operation because it is outside the integration's approved capability."
        case .scopeDenied:
            return "Perry blocked that remote write because the OAuth grant lacks its required scope."
        case .writesDisabled:
            return "Remote writes are disabled for this integration. Enable them in Settings before approving a write."
        case .providerReturned(let message):
            return message
        }
    }
}

enum OAuthPKCE {
    static func verifier() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return String((0..<64).compactMap { _ in alphabet.randomElement() })
    }

    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

@MainActor
final class OAuthCoordinator {
    private let credentialStore: OAuthCredentialStore
    private let makeSessionAgent: @MainActor (URL) -> any MCPAuthorizationUserAgent
    private let loopbackAgent: any MCPAuthorizationUserAgent
    private let openURL: @MainActor (URL) -> Bool
    private let transport: OAuthTransport
    private let sleep: @Sendable (Duration) async throws -> Void
    private var signInTask: Task<Void, Never>?

    init(
        credentialStore: OAuthCredentialStore = OAuthCredentialStore(),
        makeSessionAgent: @escaping @MainActor (URL) -> any MCPAuthorizationUserAgent = { WebAuthenticationSessionUserAgent(redirectURI: $0) },
        loopbackAgent: any MCPAuthorizationUserAgent = CustomConnectors.browserUserAgent,
        openURL: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) },
        transport: @escaping OAuthTransport = OAuthCoordinator.urlSessionTransport,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.credentialStore = credentialStore
        self.makeSessionAgent = makeSessionAgent
        self.loopbackAgent = loopbackAgent
        self.openURL = openURL
        self.transport = transport
        self.sleep = sleep
    }

    nonisolated static let urlSessionTransport: OAuthTransport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OAuthError.tokenResponseInvalid }
        return (data, http)
    }

    func authorize(
        definition: RemoteIntegrationDefinition,
        configuration: OAuthConfiguration,
        deviceCodePrompt: ((DeviceCodePrompt) -> Void)? = nil,
        completion: @escaping (Result<OAuthToken, Error>) -> Void
    ) {
        signInTask?.cancel()
        signInTask = Task { @MainActor in
            do {
                completion(.success(try await signIn(
                    definition: definition,
                    configuration: configuration,
                    deviceCodePrompt: deviceCodePrompt
                )))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func signIn(
        definition: RemoteIntegrationDefinition,
        configuration: OAuthConfiguration,
        deviceCodePrompt: ((DeviceCodePrompt) -> Void)? = nil
    ) async throws -> OAuthToken {
        try definition.requireSafeEndpoints()
        let clientID = configuration.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else { throw OAuthError.invalidClient }
        let clientSecret = configuration.clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines)
        if definition.oauthStyle.requiresClientSecret && clientSecret?.isEmpty != false {
            throw OAuthError.invalidClientSecret
        }
        let token: OAuthToken
        switch definition.redirectKind {
        case .deviceFlow:
            token = try await deviceFlow(
                definition: definition,
                clientID: clientID,
                scopes: configuration.scopes,
                prompt: deviceCodePrompt
            )
        case .customScheme:
            token = try await redirectFlow(
                agent: makeSessionAgent(configuration.redirectURI),
                definition: definition,
                configuration: configuration,
                clientID: clientID,
                clientSecret: clientSecret
            )
        case .loopback:
            token = try await redirectFlow(
                agent: loopbackAgent,
                definition: definition,
                configuration: configuration,
                clientID: clientID,
                clientSecret: clientSecret
            )
        }
        try await credentialStore.save(
            StoredOAuthCredential(
                token: token,
                clientID: clientID,
                clientSecret: clientSecret,
                grantedScopes: token.scopes.isEmpty ? Set(configuration.scopes) : token.scopes
            ),
            for: definition
        )
        return token
    }

    func token(for definition: RemoteIntegrationDefinition) async throws -> OAuthToken? {
        guard let credential = try await credentialStore.load(for: definition), !credential.token.isExpired else { return nil }
        return credential.token
    }

    func storedCredential(for definition: RemoteIntegrationDefinition) async throws -> StoredOAuthCredential? {
        try await credentialStore.load(for: definition)
    }

    func hasCredential(for definition: RemoteIntegrationDefinition) async throws -> Bool {
        try await credentialStore.load(for: definition) != nil
    }

    @discardableResult
    func disconnect(_ definition: RemoteIntegrationDefinition) async throws -> Bool {
        var revoked = false
        if let credential = try? await credentialStore.load(for: definition),
           let request = try? OAuthEndpointBuilder.revokeRequest(definition: definition, credential: credential),
           (try? definition.requireSafeEndpoints()) != nil,
           let (data, response) = try? await transport(request) {
            revoked = (200..<300).contains(response.statusCode) && Self.providerAccepted(data)
        }
        try await credentialStore.delete(for: definition)
        return revoked
    }

    func cancelAuthorization() {
        signInTask?.cancel()
        signInTask = nil
    }

    private static func providerAccepted(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = object["ok"] as? Bool else { return true }
        return ok
    }

    private func redirectFlow(
        agent: any MCPAuthorizationUserAgent,
        definition: RemoteIntegrationDefinition,
        configuration: OAuthConfiguration,
        clientID: String,
        clientSecret: String?
    ) async throws -> OAuthToken {
        let verifier = definition.oauthStyle.supportsPKCE ? OAuthPKCE.verifier() : nil
        let state = OAuthPKCE.verifier()
        let redirect = RedirectBox()
        let scopes = configuration.scopes
        let callbackURL = try await agent.authorize { redirectURI in
            redirect.set(redirectURI)
            return try Self.authorizationURL(
                definition: definition,
                clientID: clientID,
                redirectURI: redirectURI,
                scopes: scopes,
                state: state,
                verifier: verifier
            )
        }
        guard let redirectURI = redirect.value else { throw OAuthError.invalidCallback }
        return try await exchange(
            callbackURL: callbackURL,
            definition: definition,
            configuration: OAuthConfiguration(
                clientID: clientID,
                clientSecret: clientSecret,
                redirectURI: redirectURI,
                scopes: scopes
            ),
            verifier: verifier,
            expectedState: state
        )
    }

    private nonisolated static func authorizationURL(
        definition: RemoteIntegrationDefinition,
        clientID: String,
        redirectURI: URL,
        scopes: [String],
        state: String,
        verifier: String?
    ) throws -> URL {
        var components = URLComponents(url: definition.authorizationURL, resolvingAgainstBaseURL: false)
        var queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "state", value: state),
        ]
        if definition.authorizationScopeParameter == "user_scope" {
            queryItems.append(URLQueryItem(name: "scope", value: ""))
        }
        if !scopes.isEmpty {
            queryItems.append(URLQueryItem(
                name: definition.authorizationScopeParameter,
                value: scopes.joined(separator: definition.authorizationScopeSeparator)
            ))
        }
        queryItems.append(contentsOf: definition.authorizationParameters
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) })
        if let verifier {
            queryItems.append(URLQueryItem(name: "code_challenge", value: OAuthPKCE.challenge(for: verifier)))
            queryItems.append(URLQueryItem(name: "code_challenge_method", value: "S256"))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else { throw OAuthError.invalidClient }
        return url
    }

    private func deviceFlow(
        definition: RemoteIntegrationDefinition,
        clientID: String,
        scopes: [String],
        prompt: ((DeviceCodePrompt) -> Void)?
    ) async throws -> OAuthToken {
        guard let codeURL = definition.deviceAuthorizationURL else { throw OAuthError.invalidClient }
        let (codeData, codeResponse) = try await transport(OAuthEndpointBuilder.deviceCodeRequest(
            url: codeURL,
            clientID: clientID,
            scopes: scopes.joined(separator: definition.authorizationScopeSeparator)
        ))
        guard (200..<300).contains(codeResponse.statusCode) else {
            throw OAuthError.tokenExchangeFailed(codeResponse.statusCode)
        }
        guard let object = try JSONSerialization.jsonObject(with: codeData) as? [String: Any],
              let deviceCode = object["device_code"] as? String,
              let userCode = object["user_code"] as? String,
              let verificationString = object["verification_uri"] as? String,
              let verificationURL = URL(string: verificationString),
              (try? NetworkEndpointPolicy.requireSafe(verificationURL)) != nil else {
            throw OAuthError.tokenResponseInvalid
        }
        var interval = (object["interval"] as? Int) ?? 5
        let lifetime = (object["expires_in"] as? Int) ?? 900
        prompt?(DeviceCodePrompt(userCode: userCode, verificationURL: verificationURL))
        _ = openURL(verificationURL)

        var waited = 0
        while waited < lifetime {
            try await sleep(.seconds(interval))
            try Task.checkCancellation()
            waited += interval
            let (data, response) = try await transport(OAuthEndpointBuilder.deviceTokenRequest(
                definition: definition,
                clientID: clientID,
                deviceCode: deviceCode
            ))
            if let polled = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = polled["error"] as? String {
                switch error {
                case "authorization_pending":
                    continue
                case "slow_down":
                    interval = (polled["interval"] as? Int) ?? interval + 5
                    continue
                case "expired_token":
                    throw OAuthError.deviceCodeExpired
                case "access_denied":
                    throw OAuthError.cancelled
                default:
                    throw OAuthError.providerReturned((polled["error_description"] as? String) ?? error)
                }
            }
            guard (200..<300).contains(response.statusCode) else {
                throw OAuthError.tokenExchangeFailed(response.statusCode)
            }
            return try OAuthEndpointBuilder.token(from: data)
        }
        throw OAuthError.deviceCodeExpired
    }

    private func exchange(
        callbackURL: URL,
        definition: RemoteIntegrationDefinition,
        configuration: OAuthConfiguration,
        verifier: String?,
        expectedState: String
    ) async throws -> OAuthToken {
        try definition.requireSafeEndpoints()
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw OAuthError.invalidCallback
        }
        guard callbackURL.scheme?.lowercased() == configuration.redirectURI.scheme?.lowercased(),
              callbackURL.host?.lowercased() == configuration.redirectURI.host?.lowercased(),
              callbackURL.path == configuration.redirectURI.path,
              callbackURL.port == configuration.redirectURI.port else {
            throw OAuthError.invalidCallback
        }
        var callbackItems = components.queryItems ?? []
        if let fragment = components.fragment,
           let fragmentItems = URLComponents(string: "?\(fragment)")?.queryItems {
            callbackItems.append(contentsOf: fragmentItems)
        }
        if let providerError = callbackItems.first(where: { $0.name == "error" })?.value {
            let description = callbackItems.first(where: { $0.name == "error_description" })?.value
            throw OAuthError.providerReturned(description.map { "\(providerError): \($0)" } ?? providerError)
        }
        guard let code = callbackItems.first(where: { $0.name == "code" })?.value else {
            throw OAuthError.callbackMissingCode
        }
        guard callbackItems.first(where: { $0.name == "state" })?.value == expectedState else {
            throw OAuthError.stateMismatch
        }
        let request = try OAuthEndpointBuilder.authorizationCodeRequest(
            definition: definition,
            configuration: configuration,
            code: code,
            verifier: verifier
        )
        let (data, http) = try await transport(request)
        guard (200..<300).contains(http.statusCode) else { throw OAuthError.tokenExchangeFailed(http.statusCode) }
        return try OAuthEndpointBuilder.token(from: data)
    }
}

private final class RedirectBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URL?

    var value: URL? { lock.withLock { stored } }

    func set(_ url: URL) {
        lock.withLock { stored = url }
    }
}

actor RemoteIntegrationClient {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let credentialStore: OAuthCredentialStore
    private let transport: Transport
    private let permissionStore: RemoteIntegrationPermissionStore

    init(
        keychain: KeychainStore = KeychainStore(service: "dev.perry.integrations"),
        transport: Transport? = nil,
        permissionStore: RemoteIntegrationPermissionStore = RemoteIntegrationPermissionStore()
    ) {
        credentialStore = OAuthCredentialStore(keychain: keychain)
        self.permissionStore = permissionStore
        self.transport = transport ?? { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw RemoteIntegrationError.providerReturned("The provider returned a non-HTTP response.")
            }
            return (data, http)
        }
    }

    func request(
        definition: RemoteIntegrationDefinition,
        path: String,
        method: String = "GET",
        body: Data? = nil,
        writeApproved: Bool = false,
        readOnlyRequest: Bool = false
    ) async throws -> Data {
        try definition.requireSafeEndpoints()
        let normalizedMethod = method.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard definition.allowsRemoteRequest(
            path: path,
            method: normalizedMethod,
            body: body,
            readOnlyRequest: readOnlyRequest
        ) else {
            throw RemoteIntegrationError.capabilityDenied
        }
        let safeRead = normalizedMethod == "GET"
            || normalizedMethod == "HEAD"
            || (readOnlyRequest && normalizedMethod == "POST" && definition.allowsReadOnlyPost)
        guard safeRead else {
            throw RemoteIntegrationError.malformedRequest
        }
        let credential = try await validCredential(for: definition)
        return try await sendAuthorizedRequest(
            definition: definition,
            path: path,
            method: normalizedMethod,
            body: body,
            credential: credential,
            requiredScopes: [],
            requiresWritePermission: false
        )
    }

    func request(
        definition: RemoteIntegrationDefinition,
        write: RemoteIntegrationWriteRequest,
        approval: RemoteIntegrationApproval? = nil
    ) async throws -> Data {
        try definition.requireSafeEndpoints()
        guard definition.allowsRemoteWrite(write) else {
            throw RemoteIntegrationError.capabilityDenied
        }
        _ = try makeURL(baseURL: definition.baseURL, path: write.path)
        guard permissionStore.writesEnabled(for: definition) else {
            throw RemoteIntegrationError.writesDisabled
        }
        guard let storedCredential = try await credentialStore.load(for: definition) else {
            throw RemoteIntegrationError.authenticationRequired
        }
        guard write.requiredScopes.isSubset(of: storedCredential.grantedScopes) else {
            throw RemoteIntegrationError.scopeDenied
        }
        guard let approval,
              approval.matches(stepID: nil, definition: definition, request: write) else {
            throw RemoteIntegrationError.capabilityDenied
        }
        let credential = try await validCredential(for: definition)
        guard write.requiredScopes.isSubset(of: credential.grantedScopes) else {
            throw RemoteIntegrationError.scopeDenied
        }
        return try await sendAuthorizedRequest(
            definition: definition,
            path: write.path,
            method: write.method,
            body: write.body,
            credential: credential,
            requiredScopes: write.requiredScopes,
            requiresWritePermission: true
        )
    }

    func testConnection(definition: RemoteIntegrationDefinition) async throws -> String {
        let data = try await request(
            definition: definition,
            path: definition.testPath,
            method: definition.testMethod,
            body: definition.testBody,
            readOnlyRequest: definition.allowsReadOnlyPost
        )
        return connectionSummary(for: definition, data: data)
    }

    func preview(
        definition: RemoteIntegrationDefinition,
        action: RemoteIntegrationQuickAction
    ) async throws -> String {
        let data = try await request(
            definition: definition,
            path: action.path,
            method: action.method,
            body: action.bodyData,
            readOnlyRequest: action.readOnly
        )
        return responseSummary(for: definition, data: data)
    }

    func summarizedResponse(for definition: RemoteIntegrationDefinition, data: Data) -> String {
        responseSummary(for: definition, data: data)
    }

    private func validCredential(for definition: RemoteIntegrationDefinition) async throws -> StoredOAuthCredential {
        guard let credential = try await credentialStore.load(for: definition) else {
            throw RemoteIntegrationError.authenticationRequired
        }
        guard credential.token.needsRefresh else { return credential }
        return try await refreshCredential(credential, for: definition)
    }

    private func refreshCredential(
        _ credential: StoredOAuthCredential,
        for definition: RemoteIntegrationDefinition
    ) async throws -> StoredOAuthCredential {
        try definition.requireSafeEndpoints()
        guard let refreshToken = credential.token.refreshToken,
              !refreshToken.isEmpty,
              !credential.clientID.isEmpty else {
            throw RemoteIntegrationError.authenticationRequired
        }
        let request = try OAuthEndpointBuilder.refreshRequest(
            definition: definition,
            clientID: credential.clientID,
            clientSecret: credential.clientSecret,
            refreshToken: refreshToken
        )
        let (data, response) = try await transport(request)
        guard (200..<300).contains(response.statusCode) else {
            throw OAuthError.refreshFailed(response.statusCode)
        }
        let refreshedToken = try OAuthEndpointBuilder.token(from: data, fallbackRefreshToken: refreshToken)
        let refreshed = StoredOAuthCredential(
            token: refreshedToken,
            clientID: credential.clientID,
            clientSecret: credential.clientSecret,
            grantedScopes: refreshedToken.scopes.isEmpty ? credential.grantedScopes : refreshedToken.scopes
        )
        try await credentialStore.save(refreshed, for: definition)
        return refreshed
    }

    private func sendAuthorizedRequest(
        definition: RemoteIntegrationDefinition,
        path: String,
        method: String,
        body: Data?,
        credential: StoredOAuthCredential,
        requiredScopes: Set<String>,
        requiresWritePermission: Bool
    ) async throws -> Data {
        var (data, response) = try await performRequest(
            definition: definition,
            path: path,
            method: method,
            body: body,
            credential: credential,
            requiresWritePermission: requiresWritePermission
        )
        if response.statusCode == 401, credential.token.refreshToken?.isEmpty == false {
            let refreshed = try await refreshCredential(credential, for: definition)
            guard requiredScopes.isSubset(of: refreshed.grantedScopes) else {
                throw RemoteIntegrationError.scopeDenied
            }
            (data, response) = try await performRequest(
                definition: definition,
                path: path,
                method: method,
                body: body,
                credential: refreshed,
                requiresWritePermission: requiresWritePermission
            )
        }
        guard (200..<300).contains(response.statusCode) else {
            throw RemoteIntegrationError.providerReturned("The provider returned HTTP \(response.statusCode).")
        }
        try validateProviderResponse(data, definition: definition)
        return data
    }

    private func performRequest(
        definition: RemoteIntegrationDefinition,
        path: String,
        method: String,
        body: Data?,
        credential: StoredOAuthCredential,
        requiresWritePermission: Bool
    ) async throws -> (Data, HTTPURLResponse) {
        let url = try makeURL(baseURL: definition.baseURL, path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(definition.authorizationHeader(for: credential.token), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (header, value) in definition.defaultHeaders {
            request.setValue(value, forHTTPHeaderField: header)
        }
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if requiresWritePermission && !permissionStore.writesEnabled(for: definition) {
            throw RemoteIntegrationError.writesDisabled
        }
        return try await transport(request)
    }

    private func makeURL(baseURL: URL, path: String) throws -> URL {
        try NetworkEndpointPolicy.requireSafe(baseURL)
        let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedPath.hasPrefix("/"),
              !normalizedPath.contains("://"),
              !normalizedPath.contains(".."),
              !normalizedPath.contains("\\"),
              var baseComponents = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let relativeComponents = URLComponents(string: normalizedPath),
              relativeComponents.scheme == nil,
              relativeComponents.host == nil,
              relativeComponents.user == nil,
              relativeComponents.password == nil,
              relativeComponents.port == nil,
              relativeComponents.path.hasPrefix("/") else {
            throw RemoteIntegrationError.malformedRequest
        }
        let basePath = baseComponents.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let relativePath = relativeComponents.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let joinedPath = [basePath, relativePath].filter { !$0.isEmpty }.joined(separator: "/")
        baseComponents.path = "/\(joinedPath)"
        baseComponents.percentEncodedQuery = relativeComponents.percentEncodedQuery
        baseComponents.fragment = nil
        guard let url = baseComponents.url else { throw RemoteIntegrationError.malformedRequest }
        try NetworkEndpointPolicy.requireSafe(url)
        return url
    }

    private func connectionSummary(for definition: RemoteIntegrationDefinition, data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Connected to \(definition.displayName)."
        }
        switch definition.id {
        case "notion":
            let name = ((object["bot"] as? [String: Any])?["name"] as? String)
                ?? (object["workspace_name"] as? String)
            return name.map { "Connected to Notion · \($0)." } ?? "Connected to Notion."
        case "slack":
            let team = object["team"] as? String
            return team.map { "Connected to Slack · \($0)." } ?? "Connected to Slack."
        case "linear":
            let viewer = object["data"] as? [String: Any]
            let name = ((viewer?["viewer"] as? [String: Any])?["name"] as? String)
            return name.map { "Connected to Linear · \($0)." } ?? "Connected to Linear."
        case "github":
            let login = object["login"] as? String
            return login.map { "Connected to GitHub · \($0)." } ?? "Connected to GitHub."
        case "google-workspace":
            let user = object["user"] as? [String: Any]
            let name = user?["displayName"] as? String
            let email = user?["emailAddress"] as? String
            if let name, let email { return "Connected to Google · \(name) (\(email))." }
            return name.map { "Connected to Google · \($0)." } ?? "Connected to Google Workspace."
        default:
            return "Connected to \(definition.displayName)."
        }
    }

    private func validateProviderResponse(_ data: Data, definition: RemoteIntegrationDefinition) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if definition.id == "slack", let ok = object["ok"] as? Bool, !ok {
            throw RemoteIntegrationError.providerReturned(
                "Slack rejected the request: \((object["error"] as? String) ?? "unknown error")."
            )
        }
        if definition.id == "linear",
           let errors = object["errors"] as? [[String: Any]],
           let firstMessage = errors.first?["message"] as? String {
            throw RemoteIntegrationError.providerReturned("Linear rejected the request: \(firstMessage).")
        }
    }

    private func responseSummary(for definition: RemoteIntegrationDefinition, data: Data) -> String {
        let value = (try? JSONSerialization.jsonObject(with: data))
            .map(Self.redactedValue)
        guard let value,
              JSONSerialization.isValidJSONObject(value),
              let formatted = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              var text = String(data: formatted, encoding: .utf8) else {
            return "Read \(definition.displayName)."
        }
        if text.count > 6_000 {
            text = String(text.prefix(6_000)) + "\n…"
        }
        return "Read \(definition.displayName):\n\(text)"
    }

    private static func redactedValue(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, pair in
                let key = pair.key.lowercased()
                if key.contains("token") || key.contains("secret") || key.contains("password") || key.contains("authorization") || key.contains("cookie") {
                    result[pair.key] = "[redacted]"
                } else {
                    result[pair.key] = redactedValue(pair.value)
                }
            }
        }
        if let array = value as? [Any] {
            return array.map(redactedValue)
        }
        return value
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

    /// Accounts this runtime can currently write through: known definition
    /// with writes enabled. Publication validation uses this as the executor-
    /// availability floor; credential presence is still checked at dispatch.
    var executableAccountIDs: Set<String> {
        Set(definitions.values.filter { permissionStore.writesEnabled(for: $0) }.map(\.id))
    }

    /// Typed integration write. The approval grant attached to the action is
    /// the user's authorization for this exact operation and payload.
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

private enum OAuthEndpointBuilder {
    static func authorizationCodeRequest(
        definition: RemoteIntegrationDefinition,
        configuration: OAuthConfiguration,
        code: String,
        verifier: String?
    ) throws -> URLRequest {
        var request = URLRequest(url: definition.tokenURL)
        request.httpMethod = "POST"
        let clientID = configuration.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientSecret = configuration.clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines)
        var fields: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": configuration.redirectURI.absoluteString,
        ]
        switch definition.oauthStyle {
        case .basicSecret:
            guard let clientSecret, !clientSecret.isEmpty else { throw OAuthError.invalidClientSecret }
            request.setValue(basicHeader(clientID: clientID, clientSecret: clientSecret), forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        case .formSecret:
            fields["client_id"] = clientID
            if let clientSecret, !clientSecret.isEmpty { fields["client_secret"] = clientSecret }
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        case .pkce:
            fields["client_id"] = clientID
            if let clientSecret, !clientSecret.isEmpty { fields["client_secret"] = clientSecret }
            if let verifier { fields["code_verifier"] = verifier }
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        if definition.oauthStyle == .basicSecret {
            request.httpBody = try JSONSerialization.data(withJSONObject: fields)
        } else {
            request.httpBody = formData(fields)
        }
        return request
    }

    static func deviceCodeRequest(url: URL, clientID: String, scopes: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var fields = ["client_id": clientID]
        if !scopes.isEmpty { fields["scope"] = scopes }
        request.httpBody = formData(fields)
        return request
    }

    static func deviceTokenRequest(
        definition: RemoteIntegrationDefinition,
        clientID: String,
        deviceCode: String
    ) -> URLRequest {
        var request = URLRequest(url: definition.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = formData([
            "client_id": clientID,
            "device_code": deviceCode,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
        ])
        return request
    }

    static func revokeRequest(
        definition: RemoteIntegrationDefinition,
        credential: StoredOAuthCredential
    ) throws -> URLRequest? {
        guard let revocation = definition.revocation else { return nil }
        var request = URLRequest(url: revocation.url)
        request.httpMethod = "POST"
        let refreshToken = credential.token.refreshToken.flatMap { $0.isEmpty ? nil : $0 }
        let token = refreshToken ?? credential.token.accessToken
        switch revocation {
        case .tokenForm(_, let sendsTypeHint):
            var fields = ["token": token]
            if sendsTypeHint { fields["token_type_hint"] = refreshToken == nil ? "access_token" : "refresh_token" }
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = formData(fields)
        case .bearerHeader:
            request.setValue("Bearer \(credential.token.accessToken)", forHTTPHeaderField: "Authorization")
        case .basicJSON:
            guard let secret = credential.clientSecret, !secret.isEmpty, !credential.clientID.isEmpty else { return nil }
            request.setValue(basicHeader(clientID: credential.clientID, clientSecret: secret), forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            for (header, value) in definition.defaultHeaders { request.setValue(value, forHTTPHeaderField: header) }
            request.httpBody = try JSONSerialization.data(withJSONObject: ["token": credential.token.accessToken])
        }
        return request
    }

    static func refreshRequest(
        definition: RemoteIntegrationDefinition,
        clientID: String,
        clientSecret: String?,
        refreshToken: String
    ) throws -> URLRequest {
        var request = URLRequest(url: definition.tokenURL)
        request.httpMethod = "POST"
        var fields = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ]
        switch definition.oauthStyle {
        case .basicSecret:
            guard let clientSecret, !clientSecret.isEmpty else { throw OAuthError.invalidClientSecret }
            request.setValue(basicHeader(clientID: clientID, clientSecret: clientSecret), forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: fields)
        case .formSecret:
            fields["client_id"] = clientID
            if let clientSecret, !clientSecret.isEmpty { fields["client_secret"] = clientSecret }
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = formData(fields)
        case .pkce:
            fields["client_id"] = clientID
            if let clientSecret, !clientSecret.isEmpty { fields["client_secret"] = clientSecret }
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = formData(fields)
        }
        return request
    }

    static func token(from data: Data, fallbackRefreshToken: String? = nil) throws -> OAuthToken {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OAuthError.tokenResponseInvalid
        }
        if let error = object["error"] as? String, let description = object["error_description"] as? String {
            throw OAuthError.providerReturned("\(error): \(description)")
        }
        if object["access_token"] == nil, let user = object["authed_user"] as? [String: Any] {
            object = user
        }
        guard let accessToken = object["access_token"] as? String, !accessToken.isEmpty else {
            throw OAuthError.tokenResponseInvalid
        }
        let expiresAt = (object["expires_in"] as? NSNumber).map { Date().addingTimeInterval($0.doubleValue) }
        let scopes: Set<String>
        if let scope = object["scope"] as? String {
            scopes = Set(scope.split { $0 == "," || $0.isWhitespace }.map(String.init))
        } else if let scope = object["scope"] as? [String] {
            scopes = Set(scope)
        } else {
            scopes = []
        }
        return OAuthToken(
            accessToken: accessToken,
            refreshToken: object["refresh_token"] as? String ?? fallbackRefreshToken,
            tokenType: object["token_type"] as? String ?? "Bearer",
            expiresAt: expiresAt,
            scopes: scopes
        )
    }

    private static func formData(_ fields: [String: String]) -> Data? {
        var components = URLComponents()
        components.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.percentEncodedQuery?.data(using: .utf8)
    }

    private static func basicHeader(clientID: String, clientSecret: String) -> String {
        let encoded = Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
        return "Basic \(encoded)"
    }
}
