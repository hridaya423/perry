import Foundation
import PerryCore

struct MCPTokenGrant {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var scope: String?
}

enum MCPTokenEndpoint {
    private struct Response: Decodable {
        var accessToken: String
        var tokenType: String
        var expiresIn: Double?
        var refreshToken: String?
        var scope: String?
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func formEncoded(_ pairs: [(String, String)]) -> String {
        pairs.map { name, value in
            "\(name.addingPercentEncoding(withAllowedCharacters: unreserved) ?? name)=\(value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value)"
        }.joined(separator: "&")
    }

    static func request(
        _ fields: [(String, String)],
        to endpoint: URL,
        rejectedAs rejection: MCPAuthError,
        performer: any MCPHTTPPerforming,
        now: @Sendable () -> Date
    ) async throws -> MCPTokenGrant {
        try NetworkEndpointPolicy.requireSafe(endpoint)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        request.httpBody = Data(formEncoded(fields).utf8)
        let (response, data) = try await performer.data(for: request)
        switch response.statusCode {
        case 200:
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            guard let reply = try? decoder.decode(Response.self, from: data),
                  reply.tokenType.caseInsensitiveCompare("bearer") == .orderedSame,
                  !reply.accessToken.isEmpty else { throw MCPAuthError.tokenExchangeFailed }
            return MCPTokenGrant(
                accessToken: reply.accessToken, refreshToken: reply.refreshToken,
                expiresAt: reply.expiresIn.map { now().addingTimeInterval($0) }, scope: reply.scope
            )
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
            ("grant_type", "refresh_token"), ("refresh_token", refreshToken),
            ("client_id", credential.clientID), ("resource", credential.resource),
        ], to: credential.tokenEndpoint, rejectedAs: .signInRequired, performer: performer, now: now)
        var updated = credential
        updated.accessToken = grant.accessToken
        updated.refreshToken = grant.refreshToken ?? refreshToken
        updated.expiresAt = grant.expiresAt
        updated.scope = grant.scope ?? credential.scope
        return updated
    }
}
