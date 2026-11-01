import PerryBrain
import PerryCore
@testable import Perry
import XCTest

private final class FakeHostedMCP: MCPHTTPPerforming, @unchecked Sendable {
    private let lock = NSLock()
    private var accepted: String?
    private var issued = "oauth-token"
    private var refreshable = true
    private var log: [URLRequest] = []

    init(accepting accepted: String?) { self.accepted = accepted }

    var requests: [URLRequest] { lock.withLock { log } }
    func revokeEverything() { lock.withLock { accepted = "revoked"; refreshable = false } }
    func issue(_ token: String) { lock.withLock { issued = token; accepted = token } }

    func data(for request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        lock.withLock { log.append(request) }
        let (status, headers, body) = try respond(request)
        return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, body)
    }

    func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>) {
        let (response, data) = try await data(for: request)
        let text = String(decoding: data, as: UTF8.self)
        return (response, AsyncThrowingStream { continuation in
            text.split(separator: "\n", omittingEmptySubsequences: false).forEach { continuation.yield(String($0)) }
            continuation.finish()
        })
    }

    private func json(_ object: Any, status: Int = 200) throws -> (Int, [String: String], Data) {
        (status, ["Content-Type": "application/json"], try JSONSerialization.data(withJSONObject: object))
    }

    private func respond(_ request: URLRequest) throws -> (Int, [String: String], Data) {
        let url = request.url!.absoluteString
        switch (request.httpMethod ?? "GET", url) {
        case ("GET", "https://mcp.example.test/.well-known/oauth-protected-resource/mcp"):
            return try json(["resource": "https://mcp.example.test/mcp", "authorization_servers": ["https://auth.example.test"], "scopes_supported": ["read"]])
        case ("GET", "https://auth.example.test/.well-known/oauth-authorization-server"):
            return try json([
                "issuer": "https://auth.example.test", "authorization_endpoint": "https://auth.example.test/authorize",
                "token_endpoint": "https://auth.example.test/token", "registration_endpoint": "https://auth.example.test/register",
                "code_challenge_methods_supported": ["S256"], "authorization_response_iss_parameter_supported": true,
            ])
        case ("POST", "https://auth.example.test/register"):
            return try json(["client_id": "app-client"], status: 201)
        case ("POST", "https://auth.example.test/token"):
            let refreshing = String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains("grant_type=refresh_token")
            return try lock.withLock {
                if refreshing && !refreshable { return (400, [:], Data(#"{"error":"invalid_grant"}"#.utf8)) }
                return (200, ["Content-Type": "application/json"], try JSONSerialization.data(withJSONObject: [
                    "access_token": issued, "token_type": "Bearer", "expires_in": 3600, "refresh_token": "refresh-1",
                ]))
            }
        case ("POST", "https://mcp.example.test/mcp"):
            let expected = lock.withLock { accepted }
            if let expected, request.value(forHTTPHeaderField: "Authorization") != "Bearer \(expected)" {
                return (401, ["WWW-Authenticate": #"Bearer resource_metadata="https://mcp.example.test/.well-known/oauth-protected-resource/mcp""#], Data())
            }
            let message = try JSONValue(parsing: XCTUnwrap(request.httpBody))
            guard let id = message["id"] else { return (202, [:], Data()) }
            let result: JSONValue = message["method"]?.stringValue == "initialize"
                ? .object(["protocolVersion": .string(MCPServer.protocolVersion), "serverInfo": .object(["name": .string("Hosted")])])
                : .object(["tools": .array([
                    .object(["name": .string("search"), "inputSchema": .object([:]), "annotations": .object(["readOnlyHint": .bool(true)])]),
                    .object(["name": .string("mutate"), "inputSchema": .object([:])]),
                ])])
            return (200, ["Content-Type": "application/json"], try JSONValue.object(["jsonrpc": .string("2.0"), "id": id, "result": result]).data())
        default:
            return (404, [:], Data())
        }
    }
}

private final class FakeBrowser: MCPAuthorizationUserAgent, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var opened: Int { lock.withLock { count } }

    func authorize(_ makeAuthorizationURL: @Sendable (URL) async throws -> URL) async throws -> URL {
        let redirect = URL(string: "http://127.0.0.1:50000/callback")!
        let url = try await makeAuthorizationURL(redirect)
        lock.withLock { count += 1 }
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? ""
        var callback = URLComponents(url: redirect, resolvingAgainstBaseURL: false)!
        callback.queryItems = [.init(name: "code", value: "code-1"), .init(name: "state", value: state), .init(name: "iss", value: "https://auth.example.test")]
        return callback.url!
    }
}

@MainActor
final class CustomConnectorsSignInTests: XCTestCase {
    private var directory: URL!
    private var keychain: KeychainStore!
    private let hosted = CustomConnector.Endpoint.url(URL(string: "https://mcp.example.test/mcp")!)

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        keychain = KeychainStore(service: "dev.perry.connectors.tests.\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        for account in (try? keychain.accounts()) ?? [] {
            try? keychain.deleteChecked(account: account)
        }
    }

    private func make(_ host: PerryToolHost, _ remote: FakeHostedMCP, _ browser: FakeBrowser) -> CustomConnectors {
        CustomConnectors(directory: directory, host: host, keychain: keychain, http: remote, userAgent: browser)
    }

    private func settled(_ connectors: CustomConnectors, _ id: UUID) async throws -> CustomConnectors.Status {
        for _ in 0..<200 {
            if let status = connectors.status[id], status != .connecting { return status }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("connector never settled")
        return .connecting
    }

    func testAServerThatNeedsSignInOpensTheBrowserOnceKeepsTokensInTheKeychainAndStaysApprovalGated() async throws {
        let host = PerryToolHost(executors: [])
        let remote = FakeHostedMCP(accepting: "oauth-token")
        let browser = FakeBrowser()
        let connectors = make(host, remote, browser)

        let status = await connectors.add(CustomConnector(name: "Hosted", endpoint: hosted))

        XCTAssertEqual(status, .ready(toolCount: 2))
        XCTAssertEqual(browser.opened, 1)
        XCTAssertEqual(host.spec(named: "mcp.hosted.search")?.tier, .green)
        XCTAssertEqual(host.spec(named: "mcp.hosted.mutate")?.tier, .orange)
        XCTAssertEqual(connectors.connectors.first?.secret, .oauth)
        let stored = try XCTUnwrap(keychain.readChecked(account: XCTUnwrap(connectors.connectors.first).id.uuidString))
        XCTAssertTrue(stored.contains("oauth-token"))
        XCTAssertTrue(stored.contains("refresh-1"))
        let saved = try String(contentsOf: directory.appendingPathComponent("connectors.json"), encoding: .utf8)
        XCTAssertFalse(saved.contains("oauth-token"))
        XCTAssertFalse(saved.contains("refresh-1"))

        connectors.remove(try XCTUnwrap(connectors.connectors.first?.id))
        XCTAssertEqual(try keychain.accounts(), [])
    }

    func testReconnectingAtLaunchReusesTheStoredTokenWithoutTheBrowser() async throws {
        let remote = FakeHostedMCP(accepting: "oauth-token")
        let browser = FakeBrowser()
        let first = make(PerryToolHost(executors: []), remote, browser)
        _ = await first.add(CustomConnector(name: "Hosted", endpoint: hosted))
        first.disconnectAll()

        let host = PerryToolHost(executors: [])
        let relaunched = make(host, remote, browser)
        relaunched.connectAll()
        let id = try XCTUnwrap(relaunched.connectors.first?.id)

        let status = try await settled(relaunched, id)
        XCTAssertEqual(status, .ready(toolCount: 2))
        XCTAssertEqual(browser.opened, 1)
        XCTAssertNotNil(host.spec(named: "mcp.hosted.mutate"))
    }

    func testARevokedSignInWaitsForTheUserAtLaunchAndSignsInOnReconnect() async throws {
        let remote = FakeHostedMCP(accepting: "oauth-token")
        let browser = FakeBrowser()
        let first = make(PerryToolHost(executors: []), remote, browser)
        _ = await first.add(CustomConnector(name: "Hosted", endpoint: hosted))
        first.disconnectAll()
        remote.revokeEverything()

        let relaunched = make(PerryToolHost(executors: []), remote, browser)
        relaunched.connectAll()
        let id = try XCTUnwrap(relaunched.connectors.first?.id)
        let waiting = try await settled(relaunched, id)

        XCTAssertEqual(waiting, .failed("The server needs you to sign in."))
        XCTAssertEqual(browser.opened, 1)

        remote.issue("oauth-token-2")
        relaunched.reconnect(id)
        let status = try await settled(relaunched, id)
        XCTAssertEqual(status, .ready(toolCount: 2))
        XCTAssertEqual(browser.opened, 2)
        XCTAssertTrue(try XCTUnwrap(keychain.readChecked(account: id.uuidString)).contains("oauth-token-2"))
    }

    func testARefreshedSignInThatCannotBeSavedKeepsTheConnectorWorkingAndAsksToReconnect() async throws {
        let remote = FakeHostedMCP(accepting: "oauth-token")
        let browser = FakeBrowser()
        let backend = FlakyCredentialBackend()
        let first = CustomConnectors(directory: directory, host: PerryToolHost(executors: []), keychain: backend, http: remote, userAgent: browser)
        _ = await first.add(CustomConnector(name: "Hosted", endpoint: hosted))
        first.disconnectAll()
        remote.issue("rotated")
        backend.refuse(saves: true)

        let host = PerryToolHost(executors: [])
        let relaunched = CustomConnectors(directory: directory, host: host, keychain: backend, http: remote, userAgent: browser)
        relaunched.connectAll()
        let id = try XCTUnwrap(relaunched.connectors.first?.id)
        let status = try await settled(relaunched, id)

        XCTAssertEqual(status, .ready(toolCount: 2))
        XCTAssertNotNil(host.spec(named: "mcp.hosted.mutate"))
        XCTAssertEqual(browser.opened, 1)
        for _ in 0..<100 where !relaunched.signInNotSaved.contains(id) {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(relaunched.signInNotSaved, [id])

        backend.refuse(saves: false)
        relaunched.reconnect(id)
        let again = try await settled(relaunched, id)
        XCTAssertEqual(again, .ready(toolCount: 2))
        XCTAssertTrue(relaunched.signInNotSaved.isEmpty)
        XCTAssertTrue(try XCTUnwrap(backend.readCredential(account: id.uuidString)).contains("rotated"))
    }

    func testASaveFailureReportedAfterTheConnectorWasRemovedIsIgnored() async throws {
        let remote = FakeHostedMCP(accepting: "oauth-token")
        let backend = FlakyCredentialBackend()
        let first = CustomConnectors(directory: directory, host: PerryToolHost(executors: []), keychain: backend, http: remote, userAgent: FakeBrowser())
        _ = await first.add(CustomConnector(name: "Hosted", endpoint: hosted))
        first.disconnectAll()
        remote.issue("rotated")
        backend.refuse(saves: true, deletes: true)

        let relaunched = CustomConnectors(directory: directory, host: PerryToolHost(executors: []), keychain: backend, http: remote, userAgent: FakeBrowser())
        relaunched.connectAll()
        relaunched.remove(try XCTUnwrap(relaunched.connectors.first?.id))
        let refreshes = { remote.requests.filter { String(decoding: $0.httpBody ?? Data(), as: UTF8.self).contains("grant_type=refresh_token") }.count }
        for _ in 0..<100 where refreshes() == 0 {
            try await Task.sleep(for: .milliseconds(25))
        }
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertGreaterThan(refreshes(), 0)
        XCTAssertTrue(relaunched.signInNotSaved.isEmpty)
    }

    func testAStaticBearerTokenStillWorksAndNeverOpensTheBrowser() async throws {
        let remote = FakeHostedMCP(accepting: "static-key")
        let browser = FakeBrowser()
        let connectors = make(PerryToolHost(executors: []), remote, browser)

        let status = await connectors.add(CustomConnector(name: "Hosted", endpoint: hosted), secret: "static-key")

        XCTAssertEqual(status, .ready(toolCount: 2))
        XCTAssertEqual(connectors.connectors.first?.secret, .bearer)
        XCTAssertEqual(browser.opened, 0)
    }

    func testAWrongBearerTokenIsReportedAsRejectedNotAsASignInPrompt() async throws {
        let remote = FakeHostedMCP(accepting: "static-key")
        let browser = FakeBrowser()
        let connectors = make(PerryToolHost(executors: []), remote, browser)

        let status = await connectors.add(CustomConnector(name: "Hosted", endpoint: hosted), secret: "wrong")

        XCTAssertEqual(status, .failed("The server didn’t accept your key."))
        XCTAssertEqual(browser.opened, 0)
        XCTAssertTrue(connectors.connectors.isEmpty)
        XCTAssertEqual(try keychain.accounts(), [])
    }

    func testAServerWithoutAuthorizationNeedsNoSignInAndStoresNothing() async throws {
        let host = PerryToolHost(executors: [])
        let browser = FakeBrowser()
        let connectors = make(host, FakeHostedMCP(accepting: nil), browser)

        let status = await connectors.add(CustomConnector(name: "Hosted", endpoint: hosted))

        XCTAssertEqual(status, .ready(toolCount: 2))
        XCTAssertEqual(browser.opened, 0)
        XCTAssertNil(connectors.connectors.first?.secret)
        XCTAssertEqual(try keychain.accounts(), [])
    }
}
