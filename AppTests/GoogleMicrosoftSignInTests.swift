import Foundation
import XCTest
import PerryBrain
import PerryGuide
@testable import Perry

private actor Wire {
    private var requests: [URLRequest] = []
    private let respond: @Sendable (URLRequest) -> (Int, String)

    init(_ respond: @escaping @Sendable (URLRequest) -> (Int, String)) {
        self.respond = respond
    }

    func perform(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (status, body) = respond(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    func all() -> [URLRequest] { requests }
}

private final class LoopbackStub: MCPAuthorizationUserAgent, @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?

    func authorize(_ makeAuthorizationURL: @Sendable (URL) async throws -> URL) async throws -> URL {
        let redirect = URL(string: "http://127.0.0.1:49152/callback")!
        let made = try await makeAuthorizationURL(redirect)
        lock.withLock { url = made }
        let state = URLComponents(url: made, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? ""
        return URL(string: "http://127.0.0.1:49152/callback?code=g-code&state=\(state)")!
    }

    func query(_ name: String) -> String? {
        lock.withLock { url }.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == name }?.value
    }
}

private final class Memory: OAuthCredentialStoreBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func readCredential(account: String) throws -> String? { lock.withLock { values[account] } }
    func save(_ secret: String, account: String) throws { lock.withLock { values[account] = secret } }
    func deleteCredential(account: String) throws { lock.withLock { values[account] = nil } }
}

private func form(_ request: URLRequest) -> [String: String] {
    var components = URLComponents()
    components.percentEncodedQuery = request.httpBody.map { String(decoding: $0, as: UTF8.self) }
    return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
}

private func catalog(_ id: String) -> RemoteIntegrationDefinition {
    RemoteIntegrationDefinition.catalog.first { $0.id == id }!
}

private let googleToken = #"{"access_token":"ya29.a","refresh_token":"1//r","expires_in":3599,"token_type":"Bearer","scope":"https://www.googleapis.com/auth/calendar.readonly"}"#
private let calendarScope = "https://www.googleapis.com/auth/calendar.readonly"

@MainActor
final class GoogleMicrosoftSignInTests: XCTestCase {
    private func coordinator(
        store: OAuthCredentialStore = OAuthCredentialStore(backend: Memory()),
        loopback: LoopbackStub = LoopbackStub(),
        wire: Wire
    ) -> OAuthCoordinator {
        OAuthCoordinator(
            credentialStore: store,
            loopbackAgent: loopback,
            transport: { request in
                let (data, response) = await wire.perform(request)
                return (data, response)
            }
        )
    }

    func testGoogleWorkspaceIsSplitIntoCalendarDriveAndGmail() {
        let ids = RemoteIntegrationDefinition.catalog.map(\.id)

        XCTAssertFalse(ids.contains("google-workspace"))
        XCTAssertEqual(catalog("google-calendar").scopes, [calendarScope])
        XCTAssertEqual(catalog("google-drive").scopes, ["https://www.googleapis.com/auth/drive.file"])
        XCTAssertEqual(catalog("google-gmail").scopes, ["https://www.googleapis.com/auth/gmail.readonly"])
        for id in ["google-calendar", "google-drive", "google-gmail"] {
            XCTAssertEqual(catalog(id).redirectKind, .loopback, id)
            XCTAssertEqual(catalog(id).credentialAccount, "integration.\(id)")
        }
        XCTAssertEqual(catalog("microsoft").redirectKind, .loopback)
    }

    func testOnlyCalendarAndDriveShipWithAPerryClient() {
        let info: [String: Any] = [
            "PerryOAuthGoogleClientID": "g-id",
            "PerryOAuthGoogleClientSecret": "g-secret",
            "PerryOAuthNotionClientID": "n-id",
            "PerryOAuthNotionClientSecret": "n-secret",
            "PerryOAuthMicrosoftClientID": "m-id",
        ]
        let bundled = BundledOAuthClients(infoDictionary: info)

        XCTAssertEqual(bundled.client(for: catalog("google-calendar")), OAuthClientCredentials(clientID: "g-id", clientSecret: "g-secret"))
        XCTAssertEqual(bundled.client(for: catalog("google-drive")), OAuthClientCredentials(clientID: "g-id", clientSecret: "g-secret"))
        XCTAssertNil(bundled.client(for: catalog("google-gmail")))
        XCTAssertEqual(bundled.client(for: catalog("notion")), OAuthClientCredentials(clientID: "n-id", clientSecret: "n-secret"))
        XCTAssertEqual(bundled.client(for: catalog("microsoft")), OAuthClientCredentials(clientID: "m-id", clientSecret: nil))
    }

    func testNoProviderShipsAPerryClientWithoutBuildSettings() {
        let bundled = BundledOAuthClients(infoDictionary: Bundle.main.infoDictionary?.filter { !$0.key.hasPrefix("PerryOAuth") })

        for definition in RemoteIntegrationDefinition.catalog {
            XCTAssertNil(bundled.client(for: definition), definition.id)
        }
    }

    func testGoogleCalendarSignInUsesLoopbackPKCEAndTheBundledSecret() async throws {
        let calendar = catalog("google-calendar")
        let loopback = LoopbackStub()
        let wire = Wire { _ in (200, googleToken) }
        let store = OAuthCredentialStore(backend: Memory())

        _ = try await coordinator(store: store, loopback: loopback, wire: wire).signIn(
            definition: calendar,
            configuration: OAuthConfiguration(clientID: "g-id", clientSecret: "g-secret", scopes: calendar.scopes)
        )

        XCTAssertEqual(loopback.query("redirect_uri"), "http://127.0.0.1:49152/callback")
        XCTAssertEqual(loopback.query("scope"), calendarScope)
        XCTAssertEqual(loopback.query("access_type"), "offline")
        XCTAssertEqual(loopback.query("code_challenge_method"), "S256")
        let requests = await wire.all()
        let sent = form(requests[0])
        XCTAssertEqual(requests[0].url?.absoluteString, "https://oauth2.googleapis.com/token")
        XCTAssertEqual(sent["redirect_uri"], "http://127.0.0.1:49152/callback")
        XCTAssertEqual(sent["client_secret"], "g-secret")
        XCTAssertNotNil(sent["code_verifier"])
        let saved = try await store.load(for: calendar)
        XCTAssertEqual(saved?.grantedScopes, [calendarScope])
    }

    func testMicrosoftSignInIsAPublicClientOnLoopback() async throws {
        let microsoft = catalog("microsoft")
        let loopback = LoopbackStub()
        let wire = Wire { _ in (200, #"{"access_token":"EwB","refresh_token":"M.R3","expires_in":3599,"token_type":"Bearer","scope":"Mail.Read User.Read Calendars.Read Files.Read offline_access"}"#) }
        let store = OAuthCredentialStore(backend: Memory())

        _ = try await coordinator(store: store, loopback: loopback, wire: wire).signIn(
            definition: microsoft,
            configuration: OAuthConfiguration(clientID: "m-id", scopes: microsoft.scopes)
        )

        XCTAssertEqual(loopback.query("redirect_uri"), "http://127.0.0.1:49152/callback")
        XCTAssertEqual(Set(loopback.query("scope")?.split(separator: " ").map(String.init) ?? []), ["offline_access", "User.Read", "Mail.Read", "Calendars.Read", "Files.Read"])
        let requests = await wire.all()
        XCTAssertNil(form(requests[0])["client_secret"])
        XCTAssertEqual(requests[0].url?.absoluteString, "https://login.microsoftonline.com/common/oauth2/v2.0/token")
        let saved = try await store.load(for: microsoft)
        XCTAssertEqual(saved?.grantedScopes, ["Mail.Read", "User.Read", "Calendars.Read", "Files.Read", "offline_access"])
        XCTAssertTrue(microsoft.scopes.allSatisfy { !$0.lowercased().contains("write") && !$0.lowercased().contains("send") })
    }

    func testDisconnectRevokesTheGoogleGrantWithTheRefreshToken() async throws {
        let calendar = catalog("google-calendar")
        let store = OAuthCredentialStore(backend: Memory())
        try await store.save(
            StoredOAuthCredential(token: OAuthToken(accessToken: "ya29.a", refreshToken: "1//r"), clientID: "g-id", clientSecret: "g-secret"),
            for: calendar
        )
        let wire = Wire { _ in (200, "{}") }

        let revoked = try await coordinator(store: store, wire: wire).disconnect(calendar)

        XCTAssertTrue(revoked)
        let requests = await wire.all()
        XCTAssertEqual(requests[0].url?.absoluteString, "https://oauth2.googleapis.com/revoke")
        XCTAssertEqual(form(requests[0]), ["token": "1//r"])
    }

    func testDisconnectRevokesNotionWithTheClientSecret() async throws {
        let notion = catalog("notion")
        let store = OAuthCredentialStore(backend: Memory())
        try await store.save(
            StoredOAuthCredential(token: OAuthToken(accessToken: "secret_abc"), clientID: "n-id", clientSecret: "n-secret"),
            for: notion
        )
        let wire = Wire { _ in (200, #"{"request_id":"r"}"#) }

        let revoked = try await coordinator(store: store, wire: wire).disconnect(notion)

        XCTAssertTrue(revoked)
        let requests = await wire.all()
        XCTAssertEqual(requests[0].url?.absoluteString, "https://api.notion.com/v1/oauth/revoke")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Basic " + Data("n-id:n-secret".utf8).base64EncodedString())
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Notion-Version"), "2026-03-11")
        XCTAssertEqual(String(decoding: requests[0].httpBody ?? Data(), as: UTF8.self), #"{"token":"secret_abc"}"#)
    }

    func testMicrosoftHasNoRevokeEndpointToCall() async throws {
        let microsoft = catalog("microsoft")
        let store = OAuthCredentialStore(backend: Memory())
        try await store.save(
            StoredOAuthCredential(token: OAuthToken(accessToken: "EwB", refreshToken: "M.R3"), clientID: "m-id", clientSecret: nil),
            for: microsoft
        )
        let wire = Wire { _ in (200, "{}") }

        let revoked = try await coordinator(store: store, wire: wire).disconnect(microsoft)

        XCTAssertFalse(revoked)
        let requests = await wire.all()
        XCTAssertTrue(requests.isEmpty)
    }

    func testEachGoogleServiceStaysInsideItsOwnAPI() {
        let calendar = catalog("google-calendar")
        let drive = catalog("google-drive")
        let gmail = catalog("google-gmail")

        XCTAssertTrue(calendar.allowsRemoteRequest(path: "/calendar/v3/calendars/primary/events?maxResults=10", method: "GET", body: nil, readOnlyRequest: true))
        XCTAssertFalse(calendar.allowsRemoteRequest(path: "/drive/v3/files", method: "GET", body: nil, readOnlyRequest: true))
        XCTAssertTrue(drive.allowsRemoteRequest(path: "/drive/v3/files?pageSize=10", method: "GET", body: nil, readOnlyRequest: true))
        XCTAssertFalse(drive.allowsRemoteRequest(path: "/gmail/v1/users/me/messages", method: "GET", body: nil, readOnlyRequest: true))
        XCTAssertTrue(gmail.allowsRemoteRequest(path: "/gmail/v1/users/me/messages?maxResults=10", method: "GET", body: nil, readOnlyRequest: true))
        XCTAssertFalse(gmail.allowsRemoteRequest(path: "/calendar/v3/calendars/primary", method: "GET", body: nil, readOnlyRequest: true))
        for definition in [calendar, drive, gmail] {
            XCTAssertFalse(definition.allowsRemoteRequest(path: definition.testPath, method: "POST", body: Data("{}".utf8), readOnlyRequest: false), definition.id)
        }
    }

    func testMicrosoftReadsAreScopedToTheSignedInUser() {
        let microsoft = catalog("microsoft")

        XCTAssertTrue(microsoft.allowsRemoteRequest(path: "/v1.0/me/messages?$top=10&$select=subject,from", method: "GET", body: nil, readOnlyRequest: true))
        XCTAssertTrue(microsoft.allowsRemoteRequest(path: "/v1.0/me", method: "GET", body: nil, readOnlyRequest: true))
        XCTAssertFalse(microsoft.allowsRemoteRequest(path: "/v1.0/users", method: "GET", body: nil, readOnlyRequest: true))
        XCTAssertFalse(microsoft.allowsRemoteRequest(path: "/v1.0/me/sendMail", method: "POST", body: Data("{}".utf8), readOnlyRequest: false))
    }

    func testEveryDefinitionKeepsItsEndpointsSafe() throws {
        for definition in RemoteIntegrationDefinition.catalog {
            XCTAssertNoThrow(try definition.requireSafeEndpoints(), definition.id)
        }
    }
}
