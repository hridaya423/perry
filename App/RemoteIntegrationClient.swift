import Foundation
import PerryBrain
import PerryCore

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
            "That remote integration is not available."
        case .authenticationRequired:
            "Connect this remote integration again before asking Perry to use it."
        case .malformedRequest:
            "The remote integration request was incomplete."
        case .capabilityDenied:
            "Perry blocked that remote operation because it is outside the integration's approved capability."
        case .scopeDenied:
            "Perry blocked that remote write because the OAuth grant lacks its required scope."
        case .writesDisabled:
            "Remote writes are disabled for this integration. Enable them in Settings before approving a write."
        case .providerReturned(let message):
            message
        }
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

    func testConnection(definition: RemoteIntegrationDefinition) async throws -> String {
        let data = try await read(definition, definition.connectionTest)
        return Self.connectionSummary(for: definition, data: data)
    }

    func preview(definition: RemoteIntegrationDefinition, action: RemoteIntegrationQuickAction) async throws -> String {
        summarizedResponse(for: definition, data: try await read(definition, action))
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
        return try await send(
            definition,
            path: write.path,
            method: write.method,
            body: write.body,
            credential: credential,
            requiredScopes: write.requiredScopes,
            isWrite: true
        )
    }

    func summarizedResponse(for definition: RemoteIntegrationDefinition, data: Data) -> String {
        let value = (try? JSONSerialization.jsonObject(with: data)).map(Self.redactedValue)
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

    private func read(_ definition: RemoteIntegrationDefinition, _ action: RemoteIntegrationQuickAction) async throws -> Data {
        try definition.requireSafeEndpoints()
        let path = action.resolvedPath()
        guard definition.allowsRead(path: path) else {
            throw RemoteIntegrationError.capabilityDenied
        }
        let credential = try await validCredential(for: definition)
        return try await send(
            definition,
            path: path,
            method: action.method,
            body: action.bodyData,
            credential: credential,
            requiredScopes: [],
            isWrite: false
        )
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
        let request = try OAuthEndpointBuilder.tokenRequest(
            definition: definition,
            clientID: credential.clientID,
            clientSecret: credential.clientSecret,
            fields: [("grant_type", "refresh_token"), ("refresh_token", refreshToken)]
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

    private func send(
        _ definition: RemoteIntegrationDefinition,
        path: String,
        method: String,
        body: Data?,
        credential: StoredOAuthCredential,
        requiredScopes: Set<String>,
        isWrite: Bool
    ) async throws -> Data {
        var (data, response) = try await perform(definition, path: path, method: method, body: body, credential: credential, isWrite: isWrite)
        if response.statusCode == 401, credential.token.refreshToken?.isEmpty == false {
            let refreshed = try await refreshCredential(credential, for: definition)
            guard requiredScopes.isSubset(of: refreshed.grantedScopes) else {
                throw RemoteIntegrationError.scopeDenied
            }
            (data, response) = try await perform(definition, path: path, method: method, body: body, credential: refreshed, isWrite: isWrite)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw RemoteIntegrationError.providerReturned("That app didn’t answer correctly (error \(response.statusCode)). Try again.")
        }
        try Self.validateProviderResponse(data, definition: definition)
        return data
    }

    private func perform(
        _ definition: RemoteIntegrationDefinition,
        path: String,
        method: String,
        body: Data?,
        credential: StoredOAuthCredential,
        isWrite: Bool
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: try makeURL(baseURL: definition.baseURL, path: path))
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
        if isWrite && !permissionStore.writesEnabled(for: definition) {
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
        baseComponents.path = "/" + [basePath, relativePath].filter { !$0.isEmpty }.joined(separator: "/")
        baseComponents.percentEncodedQuery = relativeComponents.percentEncodedQuery
        baseComponents.fragment = nil
        guard let url = baseComponents.url else { throw RemoteIntegrationError.malformedRequest }
        try NetworkEndpointPolicy.requireSafe(url)
        return url
    }

    private static func connectionSummary(for definition: RemoteIntegrationDefinition, data: Data) -> String {
        let reply = try? JSONValue(parsing: data)
        let label = definition.connectionLabelPaths.lazy
            .compactMap { path in
                path.split(separator: ".").reduce(reply) { $0?[String($1)] }?.stringValue
            }
            .first { !$0.isEmpty }
        return label.map { "Connected to \(definition.displayName) · \($0)." } ?? "Connected to \(definition.displayName)."
    }

    private static func validateProviderResponse(_ data: Data, definition: RemoteIntegrationDefinition) throws {
        guard let reply = try? JSONValue(parsing: data) else { return }
        let failure: String?
        if reply["ok"]?.boolValue == false {
            failure = reply["error"]?.stringValue ?? "unknown error"
        } else {
            failure = reply["errors"]?.arrayValue?.first?["message"]?.stringValue
        }
        if let failure {
            throw RemoteIntegrationError.providerReturned("\(definition.displayName) rejected the request: \(failure).")
        }
    }

    private static func redactedValue(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, pair in
                let key = pair.key.lowercased()
                let secret = ["token", "secret", "password", "authorization", "cookie"].contains { key.contains($0) }
                result[pair.key] = secret ? "[redacted]" : redactedValue(pair.value)
            }
        }
        if let array = value as? [Any] {
            return array.map(redactedValue)
        }
        return value
    }
}
