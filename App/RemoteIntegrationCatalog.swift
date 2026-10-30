import Foundation
import PerryBrain
import PerryCore

struct RemoteIntegrationQuickAction: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    var method = "GET"
    let path: String
    var body: [String: JSONValue]?
    var searchField: String?

    func resolvedPath(now: Date = Date()) -> String {
        path.replacingOccurrences(of: "{now}", with: ISO8601DateFormatter().string(from: now))
    }

    var bodyData: Data? {
        body.flatMap { try? JSONValue.object($0).data() }
    }

    func searching(_ query: String) -> RemoteIntegrationQuickAction {
        guard let searchField else { return self }
        var action = self
        action.body?[searchField] = .string(query)
        return action
    }
}

struct RemoteIntegrationDefinition: Identifiable, Equatable, Sendable {
    let descriptor: IntegrationDescriptor
    let baseURL: URL
    let authorizationURL: URL
    let tokenURL: URL
    let scopes: [String]
    let writesEnabledByDefault: Bool
    let oauthStyle: OAuthClientAuth
    let authorizationParameters: [String: String]
    var redirectKind: OAuthRedirectKind = .customScheme
    var writeScopes: [String] = []
    var bundledClientKeys: BundledClientKeys?
    var deviceAuthorizationURL: URL?
    var revocation: OAuthRevocation?
    var authorizationScopeParameter = "scope"
    var authorizationScopeSeparator = " "
    var forcedTokenType: String?
    var defaultHeaders: [String: String] = [:]
    var connectionHint = "Read data from this app."
    var connectionLabelPaths: [String] = []
    var connectionTest = RemoteIntegrationQuickAction(id: "test", title: "Test connection", path: "/")
    var allowedReadPathPrefixes: [String] = []
    var allowedWritePathPrefixes: [String] = []
    var allowedWriteOperations: [RemoteIntegrationWriteOperation] = []
    var quickActions: [RemoteIntegrationQuickAction] = []

    private static let rejectedQueryFragments = [
        "accesstoken", "clientid", "clientsecret", "code", "cookie", "credential", "key",
        "password", "redirecturi", "refreshtoken", "secret", "state", "token",
    ]

    var id: String { descriptor.id }
    var displayName: String { descriptor.displayName }
    var credentialAccount: String {
        descriptor.credentialReference?.account ?? "integration.\(descriptor.id)"
    }
    var requiresClientSecret: Bool { oauthStyle.requiresClientSecret }
    var showsCallbackURL: Bool { redirectKind == .customScheme }
    var redirectInstructions: String {
        switch redirectKind {
        case .customScheme:
            "Add this callback URL in the provider’s developer settings, then enter its credentials."
        case .loopback:
            "Create a desktop-app client with a loopback redirect (http://127.0.0.1, any port), then enter its credentials."
        case .deviceFlow:
            "Enable device flow in the provider’s developer settings, then enter the client ID. No callback URL is needed."
        }
    }

    func authorizationHeader(for token: OAuthToken) -> String {
        "\(forcedTokenType ?? token.tokenType) \(token.accessToken)"
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

    func allowsRead(path: String) -> Bool {
        allows(path: path, prefixes: allowedReadPathPrefixes)
    }

    func allowsRemoteWrite(_ request: RemoteIntegrationWriteRequest) -> Bool {
        request.operation.providerID == id
            && allowedWriteOperations.contains(request.operation)
            && allows(path: request.path, prefixes: allowedWritePathPrefixes)
    }

    private func allows(path: String, prefixes: [String]) -> Bool {
        guard (try? requireSafeEndpoints()) != nil,
              let components = URLComponents(string: path),
              components.scheme == nil,
              components.host == nil,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.path.hasPrefix("/"),
              Self.hasSafeQuery(components),
              !components.path.contains(".."),
              !components.path.contains("\\") else { return false }
        return prefixes.contains { components.path == $0 || components.path.hasPrefix($0 + "/") }
    }

    private static func hasSafeQuery(_ components: URLComponents) -> Bool {
        guard let queryItems = components.queryItems else {
            return components.percentEncodedQuery == nil
        }
        return queryItems.allSatisfy { item in
            let name = item.name.lowercased().filter { $0.isLetter || $0.isNumber }
            return !rejectedQueryFragments.contains { name.contains($0) }
        }
    }
}

extension RemoteIntegrationDefinition {
    private static func descriptor(_ id: String, _ displayName: String) -> IntegrationDescriptor {
        IntegrationDescriptor(
            id: id,
            displayName: displayName,
            credentialReference: CredentialReference(service: "dev.perry.integrations", account: "integration.\(id)")
        )
    }

    private static func google(
        id: String,
        displayName: String,
        scope: String,
        bundled: Bool,
        hint: String,
        test: RemoteIntegrationQuickAction,
        labelPaths: [String],
        prefix: String,
        quickActions: [RemoteIntegrationQuickAction]
    ) -> RemoteIntegrationDefinition {
        RemoteIntegrationDefinition(
            descriptor: descriptor(id, displayName),
            baseURL: URL(string: "https://www.googleapis.com")!,
            authorizationURL: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            tokenURL: URL(string: "https://oauth2.googleapis.com/token")!,
            scopes: [scope],
            writesEnabledByDefault: false,
            oauthStyle: .pkce,
            authorizationParameters: ["access_type": "offline", "prompt": "consent"],
            redirectKind: .loopback,
            bundledClientKeys: bundled
                ? BundledClientKeys(clientIDKey: "PerryOAuthGoogleClientID", clientSecretKey: "PerryOAuthGoogleClientSecret")
                : nil,
            revocation: .tokenForm(URL(string: "https://oauth2.googleapis.com/revoke")!, sendsTypeHint: false),
            connectionHint: hint,
            connectionLabelPaths: labelPaths,
            connectionTest: test,
            allowedReadPathPrefixes: [prefix],
            quickActions: quickActions
        )
    }

    static let catalog: [RemoteIntegrationDefinition] = [
        RemoteIntegrationDefinition(
            descriptor: descriptor("notion", "Notion"),
            baseURL: URL(string: "https://api.notion.com")!,
            authorizationURL: URL(string: "https://api.notion.com/v1/oauth/authorize")!,
            tokenURL: URL(string: "https://api.notion.com/v1/oauth/token")!,
            scopes: [],
            writesEnabledByDefault: false,
            oauthStyle: .basicSecret,
            authorizationParameters: ["owner": "user"],
            bundledClientKeys: BundledClientKeys(clientIDKey: "PerryOAuthNotionClientID", clientSecretKey: "PerryOAuthNotionClientSecret"),
            revocation: .basicJSON(URL(string: "https://api.notion.com/v1/oauth/revoke")!),
            defaultHeaders: ["Notion-Version": "2026-03-11"],
            connectionHint: "Read your pages and databases.",
            connectionLabelPaths: ["bot.name", "workspace_name"],
            connectionTest: RemoteIntegrationQuickAction(id: "test", title: "Test connection", path: "/v1/users/me"),
            allowedReadPathPrefixes: ["/v1/users/me", "/v1/search", "/v1/pages", "/v1/databases", "/v1/data_sources", "/v1/blocks"],
            allowedWritePathPrefixes: ["/v1/pages", "/v1/blocks"],
            allowedWriteOperations: [.notionCreatePage, .notionUpdatePage, .notionAppendBlock],
            quickActions: [
                RemoteIntegrationQuickAction(
                    id: "search", title: "Search pages", method: "POST", path: "/v1/search",
                    body: ["page_size": .number(10)], searchField: "query"
                ),
            ]
        ),
        RemoteIntegrationDefinition(
            descriptor: descriptor("slack", "Slack"),
            baseURL: URL(string: "https://slack.com/api")!,
            authorizationURL: URL(string: "https://slack.com/oauth/v2/authorize")!,
            tokenURL: URL(string: "https://slack.com/api/oauth.v2.access")!,
            scopes: ["channels:read", "channels:history", "groups:read", "groups:history", "users:read", "team:read"],
            writesEnabledByDefault: false,
            oauthStyle: .pkce,
            authorizationParameters: [:],
            writeScopes: ["chat:write"],
            bundledClientKeys: BundledClientKeys(clientIDKey: "PerryOAuthSlackClientID", clientSecretKey: nil),
            revocation: .bearerHeader(URL(string: "https://slack.com/api/auth.revoke")!),
            authorizationScopeParameter: "user_scope",
            authorizationScopeSeparator: ",",
            forcedTokenType: "Bearer",
            connectionHint: "Read your channels and messages.",
            connectionLabelPaths: ["team"],
            connectionTest: RemoteIntegrationQuickAction(id: "test", title: "Test connection", path: "/auth.test"),
            allowedReadPathPrefixes: ["/auth.test", "/conversations.list", "/conversations.history", "/conversations.replies", "/users.list", "/team.info"],
            allowedWritePathPrefixes: ["/chat.postMessage"],
            allowedWriteOperations: [.slackSendMessage],
            quickActions: [
                RemoteIntegrationQuickAction(id: "channels", title: "List channels", path: "/conversations.list?limit=20&exclude_archived=true"),
                RemoteIntegrationQuickAction(id: "team", title: "Read workspace", path: "/team.info"),
            ]
        ),
        RemoteIntegrationDefinition(
            descriptor: descriptor("linear", "Linear"),
            baseURL: URL(string: "https://api.linear.app")!,
            authorizationURL: URL(string: "https://linear.app/oauth/authorize")!,
            tokenURL: URL(string: "https://api.linear.app/oauth/token")!,
            scopes: ["read"],
            writesEnabledByDefault: false,
            oauthStyle: .pkce,
            authorizationParameters: [:],
            writeScopes: ["write"],
            bundledClientKeys: BundledClientKeys(clientIDKey: "PerryOAuthLinearClientID", clientSecretKey: nil),
            revocation: .tokenForm(URL(string: "https://api.linear.app/oauth/revoke")!, sendsTypeHint: true),
            authorizationScopeSeparator: ",",
            connectionHint: "Read your issues and projects.",
            connectionLabelPaths: ["data.viewer.name"],
            connectionTest: RemoteIntegrationQuickAction(
                id: "test", title: "Test connection", method: "POST", path: "/graphql",
                body: ["query": .string("query { viewer { id name email } }")]
            ),
            allowedReadPathPrefixes: ["/graphql"],
            allowedWritePathPrefixes: ["/graphql"],
            allowedWriteOperations: [.linearUpdateIssue],
            quickActions: [
                RemoteIntegrationQuickAction(
                    id: "issues", title: "Read recent issues", method: "POST", path: "/graphql",
                    body: ["query": .string("query { issues(first: 10, orderBy: updatedAt) { nodes { identifier title url state { name } } } }")]
                ),
            ]
        ),
        RemoteIntegrationDefinition(
            descriptor: descriptor("github", "GitHub"),
            baseURL: URL(string: "https://api.github.com")!,
            authorizationURL: URL(string: "https://github.com/login/oauth/authorize")!,
            tokenURL: URL(string: "https://github.com/login/oauth/access_token")!,
            scopes: ["read:user", "notifications"],
            writesEnabledByDefault: false,
            oauthStyle: .pkce,
            authorizationParameters: [:],
            redirectKind: .deviceFlow,
            bundledClientKeys: BundledClientKeys(clientIDKey: "PerryOAuthGitHubClientID", clientSecretKey: nil),
            deviceAuthorizationURL: URL(string: "https://github.com/login/device/code")!,
            defaultHeaders: ["Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"],
            connectionHint: "Read your notifications.",
            connectionLabelPaths: ["login"],
            connectionTest: RemoteIntegrationQuickAction(id: "test", title: "Test connection", path: "/user"),
            allowedReadPathPrefixes: ["/user", "/notifications", "/issues"],
            quickActions: [
                RemoteIntegrationQuickAction(id: "profile", title: "Read your profile", path: "/user"),
                RemoteIntegrationQuickAction(id: "notifications", title: "Read recent notifications", path: "/notifications?per_page=10"),
                RemoteIntegrationQuickAction(id: "issues", title: "Read issues assigned to you", path: "/issues?filter=assigned&per_page=10"),
            ]
        ),
        google(
            id: "google-calendar", displayName: "Google Calendar",
            scope: "https://www.googleapis.com/auth/calendar.readonly", bundled: true,
            hint: "Read your events.",
            test: RemoteIntegrationQuickAction(id: "test", title: "Test connection", path: "/calendar/v3/calendars/primary"),
            labelPaths: ["summary"], prefix: "/calendar/v3",
            quickActions: [
                RemoteIntegrationQuickAction(
                    id: "events", title: "Read upcoming events",
                    path: "/calendar/v3/calendars/primary/events?maxResults=10&singleEvents=true&orderBy=startTime&timeMin={now}"
                ),
            ]
        ),
        google(
            id: "google-drive", displayName: "Google Drive",
            scope: "https://www.googleapis.com/auth/drive.file", bundled: true,
            hint: "Read files you open with Perry.",
            test: RemoteIntegrationQuickAction(id: "test", title: "Test connection", path: "/drive/v3/about?fields=user(displayName,emailAddress)"),
            labelPaths: ["user.displayName"], prefix: "/drive/v3",
            quickActions: [
                RemoteIntegrationQuickAction(
                    id: "files", title: "Read recent Drive files",
                    path: "/drive/v3/files?pageSize=10&orderBy=modifiedTime%20desc&fields=files(id,name,mimeType,modifiedTime)"
                ),
            ]
        ),
        google(
            id: "google-gmail", displayName: "Gmail",
            scope: "https://www.googleapis.com/auth/gmail.readonly", bundled: false,
            hint: "Read your mail. You need your own Google setup until Google reviews Perry.",
            test: RemoteIntegrationQuickAction(id: "test", title: "Test connection", path: "/gmail/v1/users/me/profile"),
            labelPaths: ["emailAddress"], prefix: "/gmail/v1",
            quickActions: [
                RemoteIntegrationQuickAction(id: "messages", title: "Read recent Gmail messages", path: "/gmail/v1/users/me/messages?maxResults=10"),
            ]
        ),
        RemoteIntegrationDefinition(
            descriptor: descriptor("microsoft", "Microsoft 365"),
            baseURL: URL(string: "https://graph.microsoft.com")!,
            authorizationURL: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!,
            tokenURL: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
            scopes: ["offline_access", "User.Read", "Mail.Read", "Calendars.Read", "Files.Read"],
            writesEnabledByDefault: false,
            oauthStyle: .pkce,
            authorizationParameters: [:],
            redirectKind: .loopback,
            bundledClientKeys: BundledClientKeys(clientIDKey: "PerryOAuthMicrosoftClientID", clientSecretKey: nil),
            connectionHint: "Read your mail, calendar and files.",
            connectionLabelPaths: ["displayName", "userPrincipalName"],
            connectionTest: RemoteIntegrationQuickAction(id: "test", title: "Test connection", path: "/v1.0/me"),
            allowedReadPathPrefixes: ["/v1.0/me"],
            quickActions: [
                RemoteIntegrationQuickAction(id: "messages", title: "Read recent Outlook messages", path: "/v1.0/me/messages?$top=10&$select=subject,from,receivedDateTime"),
                RemoteIntegrationQuickAction(id: "events", title: "Read upcoming events", path: "/v1.0/me/events?$top=10&$select=subject,start,end&$orderby=start/dateTime"),
                RemoteIntegrationQuickAction(id: "files", title: "Read recent OneDrive files", path: "/v1.0/me/drive/recent?$top=10"),
            ]
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
