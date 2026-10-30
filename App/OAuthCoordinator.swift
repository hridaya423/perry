import AppKit
import AuthenticationServices
import Foundation
import PerryBrain
import PerryCore

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
           let request = OAuthEndpointBuilder.revokeRequest(definition: definition, credential: credential),
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
        let verifier = definition.oauthStyle == .pkce ? OAuthPKCE.randomToken() : nil
        let state = OAuthPKCE.randomToken()
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
        var fields = [("grant_type", "authorization_code"), ("code", code), ("redirect_uri", configuration.redirectURI.absoluteString)]
        if let verifier { fields.append(("code_verifier", verifier)) }
        let request = try OAuthEndpointBuilder.tokenRequest(
            definition: definition,
            clientID: configuration.clientID,
            clientSecret: configuration.clientSecret,
            fields: fields
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

enum OAuthEndpointBuilder {
    static func tokenRequest(
        definition: RemoteIntegrationDefinition,
        clientID: String,
        clientSecret: String?,
        fields: [(String, String)]
    ) throws -> URLRequest {
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientSecret = clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines)
        if definition.oauthStyle == .basicSecret, clientSecret?.isEmpty != false {
            throw OAuthError.invalidClientSecret
        }
        return OAuthTokenRequest.make(
            to: definition.tokenURL, auth: definition.oauthStyle,
            clientID: clientID, clientSecret: clientSecret, fields: fields
        )
    }

    static func deviceCodeRequest(url: URL, clientID: String, scopes: String) -> URLRequest {
        formRequest(url, [("client_id", clientID)] + (scopes.isEmpty ? [] : [("scope", scopes)]))
    }

    static func deviceTokenRequest(definition: RemoteIntegrationDefinition, clientID: String, deviceCode: String) -> URLRequest {
        formRequest(definition.tokenURL, [
            ("client_id", clientID),
            ("device_code", deviceCode),
            ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
        ])
    }

    static func revokeRequest(definition: RemoteIntegrationDefinition, credential: StoredOAuthCredential) -> URLRequest? {
        guard let revocation = definition.revocation else { return nil }
        let refreshToken = credential.token.refreshToken.flatMap { $0.isEmpty ? nil : $0 }
        let token = refreshToken ?? credential.token.accessToken
        switch revocation {
        case .tokenForm(let url, let sendsTypeHint):
            var fields = [("token", token)]
            if sendsTypeHint { fields.append(("token_type_hint", refreshToken == nil ? "access_token" : "refresh_token")) }
            return formRequest(url, fields)
        case .bearerHeader(let url):
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(credential.token.accessToken)", forHTTPHeaderField: "Authorization")
            return request
        case .basicJSON(let url):
            guard let secret = credential.clientSecret, !secret.isEmpty, !credential.clientID.isEmpty else { return nil }
            var request = OAuthTokenRequest.make(
                to: url, auth: .basicSecret, clientID: credential.clientID, clientSecret: secret,
                fields: [("token", credential.token.accessToken)]
            )
            for (header, value) in definition.defaultHeaders { request.setValue(value, forHTTPHeaderField: header) }
            return request
        }
    }

    static func token(from data: Data, fallbackRefreshToken: String? = nil) throws -> OAuthToken {
        let grant: OAuthGrant
        do {
            grant = try OAuthGrant.parse(data)
        } catch OAuthGrantError.provider(let message) {
            throw OAuthError.providerReturned(message)
        } catch {
            throw OAuthError.tokenResponseInvalid
        }
        return OAuthToken(
            accessToken: grant.accessToken,
            refreshToken: grant.refreshToken ?? fallbackRefreshToken,
            tokenType: grant.tokenType ?? "Bearer",
            expiresAt: grant.expiresAt,
            scopes: grant.scopes
        )
    }

    private static func formRequest(_ url: URL, _ fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(OAuthForm.encode(fields).utf8)
        return request
    }
}
