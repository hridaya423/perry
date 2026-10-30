import Foundation
import PerryCore

enum MCPTokenEndpoint {
    static func request(
        _ fields: [(String, String)],
        clientID: String,
        to endpoint: URL,
        rejectedAs rejection: MCPAuthError,
        performer: any MCPHTTPPerforming,
        now: @Sendable () -> Date
    ) async throws -> OAuthGrant {
        try NetworkEndpointPolicy.requireSafe(endpoint)
        let request = OAuthTokenRequest.make(to: endpoint, auth: .pkce, clientID: clientID, clientSecret: nil, fields: fields)
        let (response, data) = try await performer.data(for: request)
        switch response.statusCode {
        case 200:
            guard let grant = try? OAuthGrant.parse(data, now: now()),
                  grant.tokenType?.caseInsensitiveCompare("bearer") == .orderedSame else { throw MCPAuthError.tokenExchangeFailed }
            return grant
        case 400..<500:
            throw rejection
        default:
            throw MCPAuthError.tokenExchangeFailed
        }
    }
}

public actor MCPOAuthSession {
    private var credential: MCPOAuthCredential
    private var refreshing: Task<MCPOAuthCredential, Error>?
    private let performer: any MCPHTTPPerforming
    private let now: @Sendable () -> Date
    private let persist: @Sendable (MCPOAuthCredential) -> Void

    public init(
        credential: MCPOAuthCredential,
        performer: any MCPHTTPPerforming = URLSessionMCPHTTP(),
        now: @escaping @Sendable () -> Date = { Date() },
        persist: @escaping @Sendable (MCPOAuthCredential) -> Void = { _ in }
    ) {
        self.credential = credential
        self.performer = performer
        self.now = now
        self.persist = persist
    }

    public var currentAccessToken: String { credential.accessToken }

    public func accessToken() async throws -> String {
        if credential.refreshToken != nil, let expiresAt = credential.expiresAt, expiresAt.timeIntervalSince(now()) < 60 {
            return try await refreshed(after: credential.accessToken)
        }
        return credential.accessToken
    }

    public func refreshed(after rejected: String) async throws -> String {
        guard credential.accessToken == rejected else { return credential.accessToken }
        let task: Task<MCPOAuthCredential, Error>
        if let refreshing {
            task = refreshing
        } else {
            let current = credential
            let performer = performer
            let now = now
            task = Task { try await Self.refresh(current, performer: performer, now: now) }
            refreshing = task
        }
        defer { refreshing = nil }
        let updated = try await task.value
        if credential.accessToken == rejected {
            credential = updated
            persist(updated)
        }
        return updated.accessToken
    }

    private static func refresh(_ credential: MCPOAuthCredential, performer: any MCPHTTPPerforming, now: @Sendable () -> Date) async throws -> MCPOAuthCredential {
        guard let refreshToken = credential.refreshToken else { throw MCPAuthError.signInRequired }
        let grant = try await MCPTokenEndpoint.request([
            ("grant_type", "refresh_token"), ("refresh_token", refreshToken), ("resource", credential.resource),
        ], clientID: credential.clientID, to: credential.tokenEndpoint, rejectedAs: .signInRequired, performer: performer, now: now)
        var updated = credential
        updated.accessToken = grant.accessToken
        updated.refreshToken = grant.refreshToken ?? refreshToken
        updated.expiresAt = grant.expiresAt
        updated.scope = grant.scope ?? credential.scope
        return updated
    }
}
