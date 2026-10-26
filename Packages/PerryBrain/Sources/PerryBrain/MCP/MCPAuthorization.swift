import CryptoKit
import Foundation
import PerryCore

public struct MCPAuthChallenge: Sendable, Equatable {
    public var resourceMetadata: URL?
    public var scope: String?

    public init(resourceMetadata: URL? = nil, scope: String? = nil) {
        self.resourceMetadata = resourceMetadata
        self.scope = scope
    }

    public init(wwwAuthenticate header: String?) {
        guard let header, let scheme = header.range(of: "bearer", options: .caseInsensitive) else {
            self.init()
            return
        }
        var fields: [String: String] = [:]
        for match in header[scheme.upperBound...].matches(of: #/([A-Za-z_][A-Za-z0-9_-]*)\s*=\s*(?:"((?:[^"\\]|\\.)*)"|([^\s,"]+))/#) {
            fields[String(match.1).lowercased()] = String(match.2 ?? match.3 ?? "")
        }
        self.init(resourceMetadata: fields["resource_metadata"].flatMap { URL(string: $0) }, scope: fields["scope"])
    }
}

public struct MCPUnauthorized: Error, Sendable, Equatable, LocalizedError {
    public let challenge: MCPAuthChallenge
    public init(challenge: MCPAuthChallenge) { self.challenge = challenge }
    public var errorDescription: String? { "The server needs you to sign in." }
}

public enum MCPAuthError: Error, Sendable, Equatable, LocalizedError {
    case discoveryFailed
    case pkceUnsupported
    case noClientRegistration
    case registrationFailed
    case stateMismatch
    case issuerMismatch
    case denied
    case tokenExchangeFailed
    case signInRequired
    case browserUnavailable
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .discoveryFailed: "Perry couldn’t find how to sign in to this server."
        case .pkceUnsupported: "This server’s sign-in lacks a protection Perry requires."
        case .noClientRegistration: "This server doesn’t let Perry register itself, so Perry can’t sign in."
        case .registrationFailed: "The server refused to register Perry."
        case .stateMismatch, .issuerMismatch: "The sign-in reply didn’t match Perry’s request, so Perry ignored it."
        case .denied: "Sign-in was cancelled."
        case .tokenExchangeFailed: "The server didn’t accept the sign-in."
        case .signInRequired: "Sign in again to keep using this server."
        case .browserUnavailable: "Perry couldn’t open your browser."
        case .timedOut: "Sign-in timed out."
        }
    }
}

public protocol MCPAuthorizationUserAgent: Sendable {
    func authorize(_ makeAuthorizationURL: @Sendable (_ redirectURI: URL) async throws -> URL) async throws -> URL
}

public struct MCPOAuthCredential: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var clientID: String
    public var issuer: String
    public var tokenEndpoint: URL
    public var resource: String
    public var scope: String?

    public init(accessToken: String, refreshToken: String?, expiresAt: Date?, clientID: String, issuer: String, tokenEndpoint: URL, resource: String, scope: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.clientID = clientID
        self.issuer = issuer
        self.tokenEndpoint = tokenEndpoint
        self.resource = resource
        self.scope = scope
    }
}

private struct ProtectedResourceMetadata: Decodable {
    var resource: String
    var authorizationServers: [String]
    var scopesSupported: [String]?
}

private struct AuthorizationServerMetadata: Decodable {
    var issuer: String
    var authorizationEndpoint: URL
    var tokenEndpoint: URL
    var registrationEndpoint: URL?
    var scopesSupported: [String]?
    var codeChallengeMethodsSupported: [String]?
    var clientIdMetadataDocumentSupported: Bool?
    var authorizationResponseIssParameterSupported: Bool?

    var endpoints: [URL] { [authorizationEndpoint, tokenEndpoint] + (registrationEndpoint.map { [$0] } ?? []) }
}

private final class PendingRegistration: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (clientID: String, redirectURI: URL)?
    var value: (clientID: String, redirectURI: URL)? { lock.withLock { stored } }
    func set(clientID: String, redirectURI: URL) { lock.withLock { stored = (clientID, redirectURI) } }
}

public struct MCPAuthorizer: Sendable {
    private let userAgent: any MCPAuthorizationUserAgent
    private let performer: any MCPHTTPPerforming
    private let clientName: String
    private let clientMetadataURL: URL?
    private let now: @Sendable () -> Date

    public init(
        userAgent: any MCPAuthorizationUserAgent,
        performer: any MCPHTTPPerforming = URLSessionMCPHTTP(),
        clientName: String = "Perry",
        clientMetadataURL: URL? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.userAgent = userAgent
        self.performer = performer
        self.clientName = clientName
        self.clientMetadataURL = clientMetadataURL
        self.now = now
    }

    public func signIn(resource: URL, challenge: MCPAuthChallenge) async throws -> MCPOAuthCredential {
        let protectedResource = try await discoverProtectedResource(for: resource, challenge: challenge)
        let server = try await discoverAuthorizationServer(protectedResource)
        guard server.codeChallengeMethodsSupported?.contains("S256") == true else { throw MCPAuthError.pkceUnsupported }
        let usesMetadataDocument = clientMetadataURL != nil && server.clientIdMetadataDocumentSupported == true
        guard usesMetadataDocument || server.registrationEndpoint != nil else { throw MCPAuthError.noClientRegistration }

        let verifier = Self.randomToken(byteCount: 32)
        let state = Self.randomToken(byteCount: 24)
        let scope = Self.scope(challenge: challenge, resource: protectedResource, server: server)
        let registration = PendingRegistration()

        let callback = try await userAgent.authorize { redirectURI in
            let clientID = usesMetadataDocument
                ? clientMetadataURL!.absoluteString
                : try await register(at: server.registrationEndpoint!, redirectURI: redirectURI)
            registration.set(clientID: clientID, redirectURI: redirectURI)
            var items = [
                ("response_type", "code"), ("client_id", clientID), ("redirect_uri", redirectURI.absoluteString),
                ("code_challenge", Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))),
                ("code_challenge_method", "S256"), ("state", state), ("resource", protectedResource.resource),
            ]
            if let scope { items.append(("scope", scope)) }
            guard var parts = URLComponents(url: server.authorizationEndpoint, resolvingAgainstBaseURL: false) else { throw MCPAuthError.discoveryFailed }
            let existing = parts.percentEncodedQuery
            parts.percentEncodedQuery = [existing, MCPTokenEndpoint.formEncoded(items)].compactMap { $0 }.joined(separator: "&")
            guard let url = parts.url else { throw MCPAuthError.discoveryFailed }
            return url
        }

        guard let registered = registration.value else { throw MCPAuthError.browserUnavailable }
        let code = try Self.authorizationCode(
            from: callback, state: state, issuer: server.issuer,
            issuerRequired: server.authorizationResponseIssParameterSupported == true
        )
        let grant = try await MCPTokenEndpoint.request([
            ("grant_type", "authorization_code"), ("code", code), ("redirect_uri", registered.redirectURI.absoluteString),
            ("client_id", registered.clientID), ("code_verifier", verifier), ("resource", protectedResource.resource),
        ], to: server.tokenEndpoint, rejectedAs: .tokenExchangeFailed, performer: performer, now: now)
        return MCPOAuthCredential(
            accessToken: grant.accessToken, refreshToken: grant.refreshToken, expiresAt: grant.expiresAt,
            clientID: registered.clientID, issuer: server.issuer, tokenEndpoint: server.tokenEndpoint,
            resource: protectedResource.resource, scope: grant.scope ?? scope
        )
    }

    private func discoverProtectedResource(for resource: URL, challenge: MCPAuthChallenge) async throws -> ProtectedResourceMetadata {
        for url in Self.protectedResourceURLs(for: resource, challenge: challenge) {
            if let metadata: ProtectedResourceMetadata = await get(url),
               let claimed = URL(string: metadata.resource),
               let claimedKey = Self.canonical(claimed), claimedKey == Self.canonical(resource) {
                return metadata
            }
        }
        throw MCPAuthError.discoveryFailed
    }

    private func discoverAuthorizationServer(_ resource: ProtectedResourceMetadata) async throws -> AuthorizationServerMetadata {
        for identifier in resource.authorizationServers {
            guard let issuer = URL(string: identifier), let host = issuer.host, !host.isEmpty,
                  URLComponents(url: issuer, resolvingAgainstBaseURL: false).map({ $0.query == nil && $0.fragment == nil }) == true else { continue }
            for url in Self.metadataURLs(issuer: issuer) {
                if let metadata: AuthorizationServerMetadata = await get(url), metadata.issuer == identifier,
                   metadata.endpoints.allSatisfy({ (try? NetworkEndpointPolicy.requireSafe($0)) != nil }) {
                    return metadata
                }
            }
        }
        throw MCPAuthError.discoveryFailed
    }

    private func get<T: Decodable>(_ url: URL) async -> T? {
        guard (try? NetworkEndpointPolicy.requireSafe(url)) != nil else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        guard let (response, data) = try? await performer.data(for: request), response.statusCode == 200 else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(T.self, from: data)
    }

    private func register(at endpoint: URL, redirectURI: URL) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        request.httpBody = try JSONValue.object([
            "client_name": .string(clientName),
            "redirect_uris": .array([.string(redirectURI.absoluteString)]),
            "grant_types": .array([.string("authorization_code"), .string("refresh_token")]),
            "response_types": .array([.string("code")]),
            "token_endpoint_auth_method": .string("none"),
            "application_type": .string("native"),
        ]).data()
        let (response, data) = try await performer.data(for: request)
        guard (200..<300).contains(response.statusCode),
              let reply = try? JSONValue(parsing: data),
              let clientID = reply["client_id"]?.stringValue, !clientID.isEmpty,
              (reply["token_endpoint_auth_method"]?.stringValue ?? "none") == "none" else { throw MCPAuthError.registrationFailed }
        return clientID
    }

    private static func scope(challenge: MCPAuthChallenge, resource: ProtectedResourceMetadata, server: AuthorizationServerMetadata) -> String? {
        var scopes = (challenge.scope ?? resource.scopesSupported?.joined(separator: " "))?
            .split(separator: " ").map(String.init) ?? []
        if !scopes.isEmpty, !scopes.contains("offline_access"), server.scopesSupported?.contains("offline_access") == true {
            scopes.append("offline_access")
        }
        return scopes.isEmpty ? nil : scopes.joined(separator: " ")
    }

    private static func authorizationCode(from callback: URL, state: String, issuer: String, issuerRequired: Bool) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("state") == state else { throw MCPAuthError.stateMismatch }
        if let reported = value("iss") {
            guard reported == issuer else { throw MCPAuthError.issuerMismatch }
        } else if issuerRequired {
            throw MCPAuthError.issuerMismatch
        }
        if value("error") != nil { throw MCPAuthError.denied }
        guard let code = value("code"), !code.isEmpty else { throw MCPAuthError.tokenExchangeFailed }
        return code
    }

    private static func protectedResourceURLs(for resource: URL, challenge: MCPAuthChallenge) -> [URL] {
        let urls = challenge.resourceMetadata.map { [$0] } ?? []
        guard let origin = origin(of: resource) else { return urls }
        var path = resource.path
        while path.hasSuffix("/") { path.removeLast() }
        let wellKnown = "\(origin)/.well-known/oauth-protected-resource"
        return urls + ((path.isEmpty ? [wellKnown] : [wellKnown + path, wellKnown]).compactMap { URL(string: $0) })
    }

    private static func metadataURLs(issuer: URL) -> [URL] {
        guard let origin = origin(of: issuer) else { return [] }
        var path = issuer.path
        while path.hasSuffix("/") { path.removeLast() }
        let candidates = path.isEmpty
            ? ["\(origin)/.well-known/oauth-authorization-server", "\(origin)/.well-known/openid-configuration"]
            : ["\(origin)/.well-known/oauth-authorization-server\(path)", "\(origin)/.well-known/openid-configuration\(path)", "\(origin)\(path)/.well-known/openid-configuration"]
        return candidates.compactMap { URL(string: $0) }
    }

    private static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        return "\(scheme)://\(host)\(url.port.map { ":\($0)" } ?? "")"
    }

    private static func canonical(_ url: URL) -> String? {
        guard let origin = origin(of: url), url.query == nil, url.fragment == nil else { return nil }
        var path = url.path
        while path.hasSuffix("/") { path.removeLast() }
        return origin + path
    }

    private static func randomToken(byteCount: Int) -> String {
        base64URL(Data((0..<byteCount).map { _ in UInt8.random(in: .min ... .max) }))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
