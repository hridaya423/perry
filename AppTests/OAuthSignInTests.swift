import AuthenticationServices
import Foundation
import XCTest
import PerryBrain
import PerryCore
@testable import Perry

private actor ScriptedTransport {
    typealias Handler = @Sendable (URLRequest, Int) -> (Int, String)

    private var requests: [URLRequest] = []
    private let handler: Handler

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    func perform(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (status, body) = handler(request, requests.count - 1)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }

    func all() -> [URLRequest] { requests }
}

private final class FakeAgent: MCPAuthorizationUserAgent, @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?
    private let redirect: URL
    private let callbackBase: URL
    private let code: String
    private let corruptState: Bool

    init(redirect: URL, callbackBase: URL? = nil, code: String = "code-1", corruptState: Bool = false) {
        self.redirect = redirect
        self.callbackBase = callbackBase ?? redirect
        self.code = code
        self.corruptState = corruptState
    }

    var authorizationURL: URL? { lock.withLock { url } }

    func query(_ name: String) -> String? {
        authorizationURL.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == name }?.value
    }

    func authorize(_ makeAuthorizationURL: @Sendable (URL) async throws -> URL) async throws -> URL {
        let made = try await makeAuthorizationURL(redirect)
        lock.withLock { url = made }
        let state = URLComponents(url: made, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "state" }?.value ?? ""
        var callback = URLComponents(url: callbackBase, resolvingAgainstBaseURL: false)!
        callback.queryItems = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "state", value: corruptState ? "forged" : state),
        ]
        return callback.url!
    }
}

private final class InMemoryBackend: OAuthCredentialStoreBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func readCredential(account: String) throws -> String? { lock.withLock { values[account] } }
    func save(_ secret: String, account: String) throws { lock.withLock { values[account] = secret } }
    func deleteCredential(account: String) throws { lock.withLock { values[account] = nil } }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ value: String) { lock.withLock { values.append(value) } }
    var all: [String] { lock.withLock { values } }
}

private func fields(of request: URLRequest) -> [String: String] {
    let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
    var components = URLComponents()
    components.percentEncodedQuery = body
    return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
}

private func definition(_ id: String) -> RemoteIntegrationDefinition {
    RemoteIntegrationDefinition.catalog.first { $0.id == id }!
}

private let linearToken = #"{"access_token":"lin-access","refresh_token":"lin-refresh","token_type":"Bearer","expires_in":86399,"scope":"read"}"#
private let customRedirect = URL(string: "dev.perry.perry:/oauth/callback")!

@MainActor
final class OAuthSignInTests: XCTestCase {
    private func makeCoordinator(
        store: OAuthCredentialStore = OAuthCredentialStore(backend: InMemoryBackend()),
        session: FakeAgent? = nil,
        loopback: FakeAgent? = nil,
        opened: Recorder = Recorder(),
        sleeps: Recorder = Recorder(),
        transport: ScriptedTransport
    ) -> OAuthCoordinator {
        OAuthCoordinator(
            credentialStore: store,
            makeSessionAgent: { redirect in session ?? FakeAgent(redirect: redirect) },
            loopbackAgent: loopback ?? FakeAgent(redirect: URL(string: "http://127.0.0.1:1/callback")!),
            openURL: { url in opened.add(url.absoluteString); return true },
            transport: { request in
                let (data, response) = await transport.perform(request)
                return (data, response)
            },
            sleep: { duration in sleeps.add("\(duration)") }
        )
    }

    func testCustomSchemeSignInUsesTheRegisteredRedirectAndPKCE() async throws {
        let linear = definition("linear")
        let agent = FakeAgent(redirect: customRedirect)
        let transport = ScriptedTransport { _, _ in (200, linearToken) }
        let store = OAuthCredentialStore(backend: InMemoryBackend())
        let coordinator = makeCoordinator(store: store, session: agent, transport: transport)

        let token = try await coordinator.signIn(
            definition: linear,
            configuration: OAuthConfiguration(clientID: "perry-linear", scopes: linear.scopes)
        )

        XCTAssertEqual(token.accessToken, "lin-access")
        XCTAssertEqual(agent.query("redirect_uri"), "dev.perry.perry:/oauth/callback")
        XCTAssertEqual(agent.query("client_id"), "perry-linear")
        XCTAssertEqual(agent.query("scope"), "read")
        XCTAssertEqual(agent.query("code_challenge_method"), "S256")
        let requests = await transport.all()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url, linear.tokenURL)
        let sent = fields(of: requests[0])
        XCTAssertEqual(sent["code"], "code-1")
        XCTAssertEqual(sent["redirect_uri"], "dev.perry.perry:/oauth/callback")
        XCTAssertEqual(sent["client_id"], "perry-linear")
        XCTAssertNotNil(sent["code_verifier"])
        XCTAssertNil(sent["client_secret"])
        let saved = try await store.load(for: linear)
        XCTAssertEqual(saved?.clientID, "perry-linear")
        XCTAssertEqual(saved?.grantedScopes, ["read"])
    }

    func testForgedStateIsRejectedBeforeTokenExchange() async throws {
        let linear = definition("linear")
        let transport = ScriptedTransport { _, _ in (200, linearToken) }
        let coordinator = makeCoordinator(
            session: FakeAgent(redirect: customRedirect, corruptState: true),
            transport: transport
        )

        do {
            _ = try await coordinator.signIn(
                definition: linear,
                configuration: OAuthConfiguration(clientID: "perry-linear", scopes: linear.scopes)
            )
            XCTFail("expected a state mismatch")
        } catch let error as OAuthError {
            guard case .stateMismatch = error else { return XCTFail("unexpected error: \(error)") }
        }
        let requests = await transport.all()
        XCTAssertTrue(requests.isEmpty)
    }

    func testSessionRequestsAreNotEphemeral() {
        let agent = WebAuthenticationSessionUserAgent(redirectURI: customRedirect)
        let session = agent.makeSession(url: URL(string: "https://linear.app/oauth/authorize")!) { _, _ in }

        XCTAssertFalse(session.prefersEphemeralWebBrowserSession)
        XCTAssertNotNil(session.presentationContextProvider)
    }

    func testLoopbackPortIsAcceptedAtTokenExchange() async throws {
        let loopbackLinear = RemoteIntegrationDefinition(
            descriptor: definition("linear").descriptor,
            baseURL: definition("linear").baseURL,
            authorizationURL: definition("linear").authorizationURL,
            tokenURL: definition("linear").tokenURL,
            scopes: ["read"],
            writesEnabledByDefault: false,
            oauthStyle: .pkce,
            authorizationParameters: [:],
            redirectKind: .loopback
        )
        let redirect = URL(string: "http://127.0.0.1:54321/callback")!
        let agent = FakeAgent(redirect: redirect)
        let transport = ScriptedTransport { _, _ in (200, linearToken) }
        let coordinator = makeCoordinator(loopback: agent, transport: transport)

        _ = try await coordinator.signIn(
            definition: loopbackLinear,
            configuration: OAuthConfiguration(clientID: "desktop-client", scopes: ["read"])
        )

        XCTAssertEqual(agent.query("redirect_uri"), "http://127.0.0.1:54321/callback")
        let requests = await transport.all()
        XCTAssertEqual(fields(of: requests[0])["redirect_uri"], "http://127.0.0.1:54321/callback")
    }

    func testCallbackOnAnotherLoopbackPortIsRejected() async throws {
        let linear = definition("linear")
        let loopbackLinear = RemoteIntegrationDefinition(
            descriptor: linear.descriptor,
            baseURL: linear.baseURL,
            authorizationURL: linear.authorizationURL,
            tokenURL: linear.tokenURL,
            scopes: ["read"],
            writesEnabledByDefault: false,
            oauthStyle: .pkce,
            authorizationParameters: [:],
            redirectKind: .loopback
        )
        let agent = FakeAgent(
            redirect: URL(string: "http://127.0.0.1:54321/callback")!,
            callbackBase: URL(string: "http://127.0.0.1:54322/callback")!
        )
        let transport = ScriptedTransport { _, _ in (200, linearToken) }
        let coordinator = makeCoordinator(loopback: agent, transport: transport)

        do {
            _ = try await coordinator.signIn(
                definition: loopbackLinear,
                configuration: OAuthConfiguration(clientID: "desktop-client", scopes: ["read"])
            )
            XCTFail("expected an invalid callback")
        } catch let error as OAuthError {
            guard case .invalidCallback = error else { return XCTFail("unexpected error: \(error)") }
        }
        let requests = await transport.all()
        XCTAssertTrue(requests.isEmpty)
    }

    func testRealLoopbackListenerDeliversTheCallbackToTokenExchange() async throws {
        let linear = definition("linear")
        let loopbackLinear = RemoteIntegrationDefinition(
            descriptor: linear.descriptor,
            baseURL: linear.baseURL,
            authorizationURL: linear.authorizationURL,
            tokenURL: linear.tokenURL,
            scopes: ["read"],
            writesEnabledByDefault: false,
            oauthStyle: .pkce,
            authorizationParameters: [:],
            redirectKind: .loopback
        )
        let browser = LoopbackMCPAuthorizationUserAgent(open: { url in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let redirect = items.first { $0.name == "redirect_uri" }?.value ?? ""
            let state = items.first { $0.name == "state" }?.value ?? ""
            guard let target = URL(string: "\(redirect)?code=real-code&state=\(state)") else { return false }
            Task { _ = try? await URLSession.shared.data(from: target) }
            return true
        }, timeout: .seconds(10))
        let transport = ScriptedTransport { _, _ in (200, linearToken) }
        let coordinator = OAuthCoordinator(
            credentialStore: OAuthCredentialStore(backend: InMemoryBackend()),
            loopbackAgent: browser,
            transport: { request in
                let (data, response) = await transport.perform(request)
                return (data, response)
            }
        )

        _ = try await coordinator.signIn(
            definition: loopbackLinear,
            configuration: OAuthConfiguration(clientID: "desktop-client", scopes: ["read"])
        )

        let requests = await transport.all()
        let sent = fields(of: requests[0])
        XCTAssertEqual(sent["code"], "real-code")
        XCTAssertTrue(sent["redirect_uri"]?.hasPrefix("http://127.0.0.1:") == true)
    }

    func testDeviceFlowPollsUntilTheUserApproves() async throws {
        let github = definition("github")
        let transport = ScriptedTransport { request, index in
            switch index {
            case 0:
                return (200, #"{"device_code":"dev-1","user_code":"ABCD-1234","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#)
            case 1:
                return (200, #"{"error":"authorization_pending"}"#)
            case 2:
                return (200, #"{"error":"slow_down","interval":10}"#)
            default:
                return (200, #"{"access_token":"gho_1","token_type":"bearer","scope":"read:user,notifications"}"#)
            }
        }
        let opened = Recorder()
        let sleeps = Recorder()
        let prompts = Recorder()
        let coordinator = makeCoordinator(opened: opened, sleeps: sleeps, transport: transport)

        let token = try await coordinator.signIn(
            definition: github,
            configuration: OAuthConfiguration(clientID: "perry-github", scopes: github.scopes),
            deviceCodePrompt: { prompts.add("\($0.userCode) \($0.verificationURL.absoluteString)") }
        )

        XCTAssertEqual(token.accessToken, "gho_1")
        XCTAssertEqual(token.scopes, ["read:user", "notifications"])
        XCTAssertEqual(prompts.all, ["ABCD-1234 https://github.com/login/device"])
        XCTAssertEqual(opened.all, ["https://github.com/login/device"])
        XCTAssertEqual(sleeps.all.count, 3)
        let requests = await transport.all()
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests[0].url?.absoluteString, "https://github.com/login/device/code")
        XCTAssertEqual(fields(of: requests[0])["client_id"], "perry-github")
        XCTAssertEqual(fields(of: requests[0])["scope"], github.scopes.joined(separator: " "))
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(requests[1].url?.absoluteString, "https://github.com/login/oauth/access_token")
        XCTAssertEqual(fields(of: requests[1])["device_code"], "dev-1")
        XCTAssertEqual(fields(of: requests[1])["grant_type"], "urn:ietf:params:oauth:grant-type:device_code")
        XCTAssertNil(fields(of: requests[1])["client_secret"])
    }

    func testDeviceFlowReportsAnExpiredCode() async throws {
        let github = definition("github")
        let transport = ScriptedTransport { _, index in
            index == 0
                ? (200, #"{"device_code":"dev-1","user_code":"ABCD-1234","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#)
                : (200, #"{"error":"expired_token"}"#)
        }
        let coordinator = makeCoordinator(transport: transport)

        do {
            _ = try await coordinator.signIn(
                definition: github,
                configuration: OAuthConfiguration(clientID: "perry-github", scopes: github.scopes)
            )
            XCTFail("expected an expired device code")
        } catch let error as OAuthError {
            guard case .deviceCodeExpired = error else { return XCTFail("unexpected error: \(error)") }
        }
    }

    func testDeviceFlowReportsADeniedRequest() async throws {
        let github = definition("github")
        let transport = ScriptedTransport { _, index in
            index == 0
                ? (200, #"{"device_code":"dev-1","user_code":"ABCD-1234","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#)
                : (200, #"{"error":"access_denied"}"#)
        }
        let coordinator = makeCoordinator(transport: transport)

        do {
            _ = try await coordinator.signIn(
                definition: github,
                configuration: OAuthConfiguration(clientID: "perry-github", scopes: github.scopes)
            )
            XCTFail("expected a denied request")
        } catch let error as OAuthError {
            guard case .cancelled = error else { return XCTFail("unexpected error: \(error)") }
        }
    }

    func testSlackUserTokenIsReadFromTheNestedAuthedUser() async throws {
        let slack = definition("slack")
        let transport = ScriptedTransport { _, _ in
            (200, #"{"ok":true,"app_id":"A1","authed_user":{"id":"U1","scope":"channels:read,channels:history","access_token":"xoxp-1","token_type":"user","refresh_token":"xoxe-1","expires_in":43200},"team":{"id":"T1"}}"#)
        }
        let store = OAuthCredentialStore(backend: InMemoryBackend())
        let agent = FakeAgent(redirect: customRedirect)
        let coordinator = makeCoordinator(store: store, session: agent, transport: transport)

        let token = try await coordinator.signIn(
            definition: slack,
            configuration: OAuthConfiguration(clientID: "perry-slack", scopes: slack.scopes)
        )

        XCTAssertEqual(token.accessToken, "xoxp-1")
        XCTAssertEqual(token.refreshToken, "xoxe-1")
        let saved = try await store.load(for: slack)
        XCTAssertEqual(saved?.grantedScopes, ["channels:read", "channels:history"])
        XCTAssertEqual(agent.query("user_scope"), slack.scopes.joined(separator: ","))
    }

    func testFirstConsentRequestsOnlyReadScopes() async throws {
        let writeScopes = Set(RemoteIntegrationWriteOperation.allCases.flatMap { $0.requiredScopes })
        for definition in RemoteIntegrationDefinition.catalog {
            XCTAssertTrue(
                Set(definition.scopes).isDisjoint(with: writeScopes),
                "\(definition.id) asks for a write scope at first consent"
            )
            XCTAssertTrue(
                Set(definition.scopes).isDisjoint(with: definition.writeScopes),
                "\(definition.id) lists a write scope as a read scope"
            )
        }
        XCTAssertEqual(definition("slack").writeScopes, ["chat:write"])
        XCTAssertEqual(definition("linear").writeScopes, ["write"])

        let slack = definition("slack")
        let agent = FakeAgent(redirect: customRedirect)
        let transport = ScriptedTransport { _, _ in (200, #"{"ok":true,"authed_user":{"access_token":"x","scope":"channels:read"}}"#) }
        _ = try await makeCoordinator(session: agent, transport: transport).signIn(
            definition: slack,
            configuration: OAuthConfiguration(clientID: "perry-slack", scopes: slack.scopes)
        )
        XCTAssertFalse(agent.query("user_scope")?.contains("chat:write") ?? true)
    }

    func testBundledClientsComeFromInfoPlistAndIgnoreEmptyValues() {
        let linear = definition("linear")
        let github = definition("github")
        let filled = BundledOAuthClients(infoDictionary: [
            "PerryOAuthLinearClientID": "lin-id",
            "PerryOAuthGitHubClientID": "$(PERRY_OAUTH_GITHUB_CLIENT_ID)",
        ])
        let empty = BundledOAuthClients(infoDictionary: ["PerryOAuthLinearClientID": "  "])

        XCTAssertEqual(filled.client(for: linear), OAuthClientCredentials(clientID: "lin-id", clientSecret: nil))
        XCTAssertNil(filled.client(for: github))
        XCTAssertNil(empty.client(for: linear))
        XCTAssertNil(BundledOAuthClients(infoDictionary: nil).client(for: linear))
    }

    func testConnectWithoutAnyClientFailsAndWithBundledClientUsesIt() async throws {
        let linear = definition("linear")
        let agent = FakeAgent(redirect: customRedirect)
        let transport = ScriptedTransport { _, _ in (200, linearToken) }
        let coordinator = makeCoordinator(session: agent, transport: transport)
        let suite = "dev.perry.tests.oauth-signin.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let permissions = RemoteIntegrationPermissionStore(suiteName: suite)
        let client = RemoteIntegrationClient(
            keychain: KeychainStore(service: "dev.perry.tests.integration.\(UUID().uuidString)"),
            transport: { _ in throw URLError(.cancelled) },
            permissionStore: permissions
        )
        let bare = IntegrationConnections(oauth: coordinator, client: client, permissions: permissions, bundled: BundledOAuthClients(infoDictionary: nil))
        let bundled = IntegrationConnections(
            oauth: coordinator,
            client: client,
            permissions: permissions,
            bundled: BundledOAuthClients(infoDictionary: ["PerryOAuthLinearClientID": "lin-id"])
        )
        XCTAssertFalse(bare.hasBundledClient(linear))
        XCTAssertTrue(bundled.hasBundledClient(linear))

        let failed = expectation(description: "no client")
        bare.connect(linear) { result in
            if case .failure(let error) = result, case OAuthError.invalidClient = error { failed.fulfill() }
        }
        await fulfillment(of: [failed], timeout: 5)

        let connected = expectation(description: "bundled client")
        bundled.connect(linear) { result in
            if case .success = result { connected.fulfill() }
        }
        await fulfillment(of: [connected], timeout: 5)
        XCTAssertEqual(agent.query("client_id"), "lin-id")
    }

    func testTurningOnWritesAsksForTheWriteScopesOnce() async throws {
        let linear = definition("linear")
        let store = OAuthCredentialStore(backend: InMemoryBackend())
        try await store.save(
            StoredOAuthCredential(token: OAuthToken(accessToken: "old", scopes: ["read"]), clientID: "perry-linear", clientSecret: nil),
            for: linear
        )
        let agent = FakeAgent(redirect: customRedirect)
        let transport = ScriptedTransport { _, _ in
            (200, #"{"access_token":"new","token_type":"Bearer","expires_in":86399,"scope":"read,write"}"#)
        }
        let suite = "dev.perry.tests.oauth-stepup.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let permissions = RemoteIntegrationPermissionStore(suiteName: suite)
        let coordinator = makeCoordinator(store: store, session: agent, transport: transport)
        let connections = IntegrationConnections(
            oauth: coordinator,
            client: RemoteIntegrationClient(
                keychain: KeychainStore(service: "dev.perry.tests.integration.\(UUID().uuidString)"),
                transport: { _ in throw URLError(.cancelled) },
                permissionStore: permissions
            ),
            permissions: permissions,
            bundled: BundledOAuthClients(infoDictionary: nil)
        )

        let first = expectation(description: "step up")
        connections.setWrites(true, for: linear) { result in
            if case .success(true) = result { first.fulfill() }
        }
        await fulfillment(of: [first], timeout: 5)

        XCTAssertEqual(agent.query("scope"), "read,write")
        XCTAssertTrue(permissions.writesEnabled(for: linear))
        let saved = try await store.load(for: linear)
        XCTAssertEqual(saved?.grantedScopes, ["read", "write"])
        XCTAssertEqual(saved?.clientID, "perry-linear")

        let second = expectation(description: "already granted")
        permissions.setWritesEnabled(false, for: linear)
        let before = await transport.all().count
        connections.setWrites(true, for: linear) { result in
            if case .success(true) = result { second.fulfill() }
        }
        await fulfillment(of: [second], timeout: 5)
        let after = await transport.all().count
        XCTAssertEqual(before, after)
        XCTAssertTrue(permissions.writesEnabled(for: linear))
    }

    func testDeclinedStepUpLeavesWritesOff() async throws {
        let slack = definition("slack")
        let store = OAuthCredentialStore(backend: InMemoryBackend())
        try await store.save(
            StoredOAuthCredential(token: OAuthToken(accessToken: "old", scopes: ["channels:read"]), clientID: "perry-slack", clientSecret: nil),
            for: slack
        )
        let transport = ScriptedTransport { _, _ in (200, "{}") }
        let suite = "dev.perry.tests.oauth-declined.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let permissions = RemoteIntegrationPermissionStore(suiteName: suite)
        let coordinator = makeCoordinator(
            store: store,
            session: FakeAgent(redirect: customRedirect, corruptState: true),
            transport: transport
        )
        let connections = IntegrationConnections(
            oauth: coordinator,
            client: RemoteIntegrationClient(
                keychain: KeychainStore(service: "dev.perry.tests.integration.\(UUID().uuidString)"),
                transport: { _ in throw URLError(.cancelled) },
                permissionStore: permissions
            ),
            permissions: permissions,
            bundled: BundledOAuthClients(infoDictionary: nil)
        )

        let failed = expectation(description: "step up fails")
        connections.setWrites(true, for: slack) { result in
            if case .failure = result { failed.fulfill() }
        }
        await fulfillment(of: [failed], timeout: 5)
        XCTAssertFalse(permissions.writesEnabled(for: slack))
    }

    func testDisconnectRevokesLinearAtTheProviderAndForgetsTheCredential() async throws {
        let linear = definition("linear")
        let store = OAuthCredentialStore(backend: InMemoryBackend())
        try await store.save(
            StoredOAuthCredential(token: OAuthToken(accessToken: "lin-access", refreshToken: "lin-refresh"), clientID: "perry-linear", clientSecret: nil),
            for: linear
        )
        let transport = ScriptedTransport { _, _ in (200, "{}") }
        let coordinator = makeCoordinator(store: store, transport: transport)

        let revoked = try await coordinator.disconnect(linear)

        XCTAssertTrue(revoked)
        let requests = await transport.all()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url?.absoluteString, "https://api.linear.app/oauth/revoke")
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(fields(of: requests[0])["token"], "lin-refresh")
        XCTAssertEqual(fields(of: requests[0])["token_type_hint"], "refresh_token")
        let afterwards = try await store.load(for: linear)
        XCTAssertNil(afterwards)
    }

    func testDisconnectRevokesSlackWithTheBearerToken() async throws {
        let slack = definition("slack")
        let store = OAuthCredentialStore(backend: InMemoryBackend())
        try await store.save(
            StoredOAuthCredential(token: OAuthToken(accessToken: "xoxp-1", refreshToken: "xoxe-1"), clientID: "perry-slack", clientSecret: nil),
            for: slack
        )
        let transport = ScriptedTransport { _, _ in (200, #"{"ok":true,"revoked":true}"#) }
        let coordinator = makeCoordinator(store: store, transport: transport)

        let revoked = try await coordinator.disconnect(slack)

        XCTAssertTrue(revoked)
        let requests = await transport.all()
        XCTAssertEqual(requests[0].url?.absoluteString, "https://slack.com/api/auth.revoke")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer xoxp-1")
    }

    func testDisconnectStillForgetsTheCredentialWhenTheProviderIsUnreachable() async throws {
        let linear = definition("linear")
        let store = OAuthCredentialStore(backend: InMemoryBackend())
        try await store.save(
            StoredOAuthCredential(token: OAuthToken(accessToken: "lin-access"), clientID: "perry-linear", clientSecret: nil),
            for: linear
        )
        let coordinator = OAuthCoordinator(
            credentialStore: store,
            transport: { _ in throw URLError(.notConnectedToInternet) }
        )

        let revoked = try await coordinator.disconnect(linear)

        XCTAssertFalse(revoked)
        let afterwards = try await store.load(for: linear)
        XCTAssertNil(afterwards)
    }

    func testDisconnectWithoutAProviderRevokeEndpointOnlyForgetsTheCredential() async throws {
        let github = definition("github")
        let store = OAuthCredentialStore(backend: InMemoryBackend())
        try await store.save(
            StoredOAuthCredential(token: OAuthToken(accessToken: "gho_1"), clientID: "perry-github", clientSecret: nil),
            for: github
        )
        let transport = ScriptedTransport { _, _ in (200, "{}") }
        let coordinator = makeCoordinator(store: store, transport: transport)

        let revoked = try await coordinator.disconnect(github)

        XCTAssertFalse(revoked)
        let requests = await transport.all()
        XCTAssertTrue(requests.isEmpty)
        let afterwards = try await store.load(for: github)
        XCTAssertNil(afterwards)
    }

    func testRedirectKindsPerProvider() {
        XCTAssertEqual(definition("linear").redirectKind, .customScheme)
        XCTAssertEqual(definition("slack").redirectKind, .customScheme)
        XCTAssertEqual(definition("github").redirectKind, .deviceFlow)
    }
}
