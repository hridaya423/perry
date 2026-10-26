import CryptoKit
import Foundation
import Network
import PerryCore
import XCTest
@testable import PerryBrain

private let mcpURL = URL(string: "https://mcp.linear.app/mcp")!
private let issuer = "https://mcp.linear.app"
private let clock = Date(timeIntervalSince1970: 1_800_000_000)

private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/linear-mcp")))
}

private func form(_ request: URLRequest) -> [String: String] {
    let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
    var fields: [String: String] = [:]
    for pair in body.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
        fields[parts[0]] = (parts.count > 1 ? parts[1] : "").removingPercentEncoding
    }
    return fields
}

private func query(_ url: URL) -> [String: String] {
    Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
}

private final class FakeWorld: MCPHTTPPerforming, @unchecked Sendable {
    typealias Reply = (status: Int, headers: [String: String], body: Data)
    private let lock = NSLock()
    private var routes: [String: (URLRequest) throws -> Reply] = [:]
    private var log: [URLRequest] = []

    var requests: [URLRequest] { lock.withLock { log } }
    func urls(_ method: String) -> [String] { requests.filter { $0.httpMethod == method }.map { $0.url!.absoluteString } }

    func route(_ method: String, _ url: String, _ reply: @escaping (URLRequest) throws -> Reply) {
        lock.withLock { routes["\(method) \(url)"] = reply }
    }

    func serve(_ method: String, _ url: String, _ body: Data, status: Int = 200) {
        route(method, url) { _ in (status, ["Content-Type": "application/json"], body) }
    }

    func data(for request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        let handler = lock.withLock { () -> ((URLRequest) throws -> Reply)? in
            log.append(request)
            return routes["\(request.httpMethod ?? "GET") \(request.url!.absoluteString)"]
        }
        let reply: Reply = try handler?(request) ?? (404, [:], Data())
        return (HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!, reply.body)
    }

    func lines(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>) {
        let (response, data) = try await data(for: request)
        let text = String(data: data, encoding: .utf8) ?? ""
        return (response, AsyncThrowingStream { continuation in
            text.split(separator: "\n", omittingEmptySubsequences: false).forEach { continuation.yield(String($0)) }
            continuation.finish()
        })
    }
}

private final class FakeUserAgent: MCPAuthorizationUserAgent, @unchecked Sendable {
    static let redirect = URL(string: "http://127.0.0.1:53682/callback")!
    private let lock = NSLock()
    private var opened: URL?
    var respond: @Sendable (_ authorizationURL: URL) -> URL = { url in
        var parts = URLComponents(url: FakeUserAgent.redirect, resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "code", value: "auth-code"), .init(name: "state", value: query(url)["state"]), .init(name: "iss", value: issuer)]
        return parts.url!
    }

    var authorizationURL: URL? { lock.withLock { opened } }

    func authorize(_ makeAuthorizationURL: @Sendable (URL) async throws -> URL) async throws -> URL {
        let url = try await makeAuthorizationURL(Self.redirect)
        lock.withLock { opened = url }
        return respond(url)
    }
}

private func callback(_ items: [String: String]) -> URL {
    var parts = URLComponents(url: FakeUserAgent.redirect, resolvingAgainstBaseURL: false)!
    parts.queryItems = items.map { .init(name: $0.key, value: $0.value) }
    return parts.url!
}

private func tokenReply(access: String = "at-1", refresh: String? = "rt-1", expiresIn: Int = 3600) -> FakeWorld.Reply {
    var fields: [String: Any] = ["access_token": access, "token_type": "Bearer", "expires_in": expiresIn, "scope": "read write"]
    if let refresh { fields["refresh_token"] = refresh }
    return (200, ["Content-Type": "application/json"], try! JSONSerialization.data(withJSONObject: fields))
}

private func linearWorld() throws -> FakeWorld {
    let world = FakeWorld()
    world.serve("GET", "https://mcp.linear.app/.well-known/oauth-protected-resource/mcp", try fixture("protected-resource"))
    world.serve("GET", "https://mcp.linear.app/.well-known/oauth-authorization-server", try fixture("authorization-server"))
    world.route("POST", "https://mcp.linear.app/register") { _ in
        (201, ["Content-Type": "application/json"], Data(#"{"client_id":"dcr-client","token_endpoint_auth_method":"none"}"#.utf8))
    }
    world.route("POST", "https://mcp.linear.app/token") { _ in tokenReply() }
    return world
}

private let linearChallenge = MCPAuthChallenge(
    resourceMetadata: URL(string: "https://mcp.linear.app/.well-known/oauth-protected-resource/mcp"),
    scope: "read write"
)

private func authorizer(_ world: FakeWorld, _ agent: FakeUserAgent, metadata: URL? = nil) -> MCPAuthorizer {
    MCPAuthorizer(userAgent: agent, performer: world, clientName: "Perry", clientMetadataURL: metadata, now: { clock })
}

private func credential(expiresIn: TimeInterval = 3600, refresh: String? = "rt-1") -> MCPOAuthCredential {
    MCPOAuthCredential(
        accessToken: "at-1", refreshToken: refresh, expiresAt: clock.addingTimeInterval(expiresIn),
        clientID: "dcr-client", issuer: issuer, tokenEndpoint: URL(string: "https://mcp.linear.app/token")!,
        resource: "https://mcp.linear.app/mcp", scope: "read write"
    )
}

private func assertSignInFails(_ expected: MCPAuthError, _ world: FakeWorld, _ agent: FakeUserAgent = FakeUserAgent(), challenge: MCPAuthChallenge = linearChallenge, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await authorizer(world, agent).signIn(resource: mcpURL, challenge: challenge)
        XCTFail("expected \(expected)", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? MCPAuthError, expected, file: file, line: line)
    }
}

final class MCPChallengeTests: XCTestCase {
    func testParsesResourceMetadataAndScopeFromTheBearerChallenge() {
        let challenge = MCPAuthChallenge(wwwAuthenticate: #"Bearer realm="OAuth", resource_metadata="https://mcp.linear.app/.well-known/oauth-protected-resource/mcp", scope="read write""#)
        XCTAssertEqual(challenge, linearChallenge)
    }

    func testIgnoresOtherSchemesAndMissingHeaders() {
        XCTAssertEqual(MCPAuthChallenge(wwwAuthenticate: nil), MCPAuthChallenge())
        XCTAssertEqual(MCPAuthChallenge(wwwAuthenticate: #"Basic realm="x""#), MCPAuthChallenge())
        XCTAssertEqual(
            MCPAuthChallenge(wwwAuthenticate: #"Basic realm="x", bearer resource_metadata="https://a.example/m", error=invalid_token"#),
            MCPAuthChallenge(resourceMetadata: URL(string: "https://a.example/m"))
        )
    }
}

final class MCPAuthorizerTests: XCTestCase {
    func testSignsInThroughDiscoveryRegistrationPKCEAndTokenExchange() async throws {
        let world = try linearWorld()
        let agent = FakeUserAgent()

        let result = try await authorizer(world, agent).signIn(resource: mcpURL, challenge: linearChallenge)

        XCTAssertEqual(world.requests.map { "\($0.httpMethod!) \($0.url!.absoluteString)" }, [
            "GET https://mcp.linear.app/.well-known/oauth-protected-resource/mcp",
            "GET https://mcp.linear.app/.well-known/oauth-authorization-server",
            "POST https://mcp.linear.app/register",
            "POST https://mcp.linear.app/token",
        ])

        let registration = try JSONSerialization.jsonObject(with: XCTUnwrap(world.requests[2].httpBody)) as? [String: Any]
        XCTAssertEqual(registration?["redirect_uris"] as? [String], [FakeUserAgent.redirect.absoluteString])
        XCTAssertEqual(registration?["application_type"] as? String, "native")
        XCTAssertEqual(registration?["token_endpoint_auth_method"] as? String, "none")
        XCTAssertEqual(registration?["client_name"] as? String, "Perry")
        XCTAssertEqual(registration?["grant_types"] as? [String], ["authorization_code", "refresh_token"])

        let authorization = query(try XCTUnwrap(agent.authorizationURL))
        XCTAssertEqual(agent.authorizationURL?.host, "mcp.linear.app")
        XCTAssertEqual(agent.authorizationURL?.path, "/authorize")
        XCTAssertEqual(authorization["response_type"], "code")
        XCTAssertEqual(authorization["client_id"], "dcr-client")
        XCTAssertEqual(authorization["redirect_uri"], FakeUserAgent.redirect.absoluteString)
        XCTAssertEqual(authorization["resource"], "https://mcp.linear.app/mcp")
        XCTAssertEqual(authorization["scope"], "read write")
        XCTAssertEqual(authorization["code_challenge_method"], "S256")
        XCTAssertGreaterThanOrEqual(authorization["state"]?.count ?? 0, 16)

        let token = form(world.requests[3])
        XCTAssertEqual(token["grant_type"], "authorization_code")
        XCTAssertEqual(token["code"], "auth-code")
        XCTAssertEqual(token["client_id"], "dcr-client")
        XCTAssertEqual(token["redirect_uri"], FakeUserAgent.redirect.absoluteString)
        XCTAssertEqual(token["resource"], "https://mcp.linear.app/mcp")
        let verifier = try XCTUnwrap(token["code_verifier"])
        XCTAssertGreaterThanOrEqual(verifier.count, 43)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(authorization["code_challenge"], challenge)

        XCTAssertEqual(result, MCPOAuthCredential(
            accessToken: "at-1", refreshToken: "rt-1", expiresAt: clock.addingTimeInterval(3600),
            clientID: "dcr-client", issuer: issuer, tokenEndpoint: URL(string: "https://mcp.linear.app/token")!,
            resource: "https://mcp.linear.app/mcp", scope: "read write"
        ))
    }

    func testUsesTheClientMetadataDocumentWhenTheServerSupportsItAndNeverRegisters() async throws {
        let world = try linearWorld()
        let agent = FakeUserAgent()
        let document = URL(string: "https://perry.example/oauth/client.json")!

        let result = try await authorizer(world, agent, metadata: document).signIn(resource: mcpURL, challenge: linearChallenge)

        XCTAssertEqual(result.clientID, document.absoluteString)
        XCTAssertEqual(query(try XCTUnwrap(agent.authorizationURL))["client_id"], document.absoluteString)
        XCTAssertEqual(form(try XCTUnwrap(world.requests.last))["client_id"], document.absoluteString)
        XCTAssertTrue(world.urls("POST").allSatisfy { !$0.hasSuffix("/register") })
    }

    func testFallsBackToWellKnownUrisWhenTheChallengeHasNoMetadataUrl() async throws {
        let world = try linearWorld()

        _ = try await authorizer(world, FakeUserAgent()).signIn(resource: mcpURL, challenge: MCPAuthChallenge(scope: nil))

        XCTAssertEqual(world.urls("GET").first, "https://mcp.linear.app/.well-known/oauth-protected-resource/mcp")
        let root = FakeWorld()
        root.serve("GET", "https://mcp.linear.app/.well-known/oauth-protected-resource", Data(#"{"resource":"https://mcp.linear.app/mcp","authorization_servers":["https://mcp.linear.app"],"scopes_supported":["read"]}"#.utf8))
        root.serve("GET", "https://mcp.linear.app/.well-known/oauth-authorization-server", try fixture("authorization-server"))
        root.route("POST", "https://mcp.linear.app/register") { _ in (201, [:], Data(#"{"client_id":"c"}"#.utf8)) }
        root.route("POST", "https://mcp.linear.app/token") { _ in tokenReply() }
        let agent = FakeUserAgent()
        _ = try await authorizer(root, agent).signIn(resource: mcpURL, challenge: MCPAuthChallenge())
        XCTAssertEqual(root.urls("GET").prefix(2), [
            "https://mcp.linear.app/.well-known/oauth-protected-resource/mcp",
            "https://mcp.linear.app/.well-known/oauth-protected-resource",
        ])
        XCTAssertEqual(query(try XCTUnwrap(agent.authorizationURL))["scope"], "read")
    }

    func testAuthorizationServerMetadataTriesOAuthThenOpenIDWithPathInsertion() async throws {
        let world = FakeWorld()
        world.serve("GET", "https://mcp.linear.app/.well-known/oauth-protected-resource/mcp", Data(#"{"resource":"https://mcp.linear.app/mcp","authorization_servers":["https://auth.example.com/tenant1"]}"#.utf8))
        let metadata = #"{"issuer":"https://auth.example.com/tenant1","authorization_endpoint":"https://auth.example.com/tenant1/authorize","token_endpoint":"https://auth.example.com/tenant1/token","registration_endpoint":"https://auth.example.com/tenant1/register","code_challenge_methods_supported":["S256"]}"#
        world.serve("GET", "https://auth.example.com/tenant1/.well-known/openid-configuration", Data(metadata.utf8))
        world.route("POST", "https://auth.example.com/tenant1/register") { _ in (201, [:], Data(#"{"client_id":"c"}"#.utf8)) }
        world.route("POST", "https://auth.example.com/tenant1/token") { _ in tokenReply() }
        let agent = FakeUserAgent()
        agent.respond = { url in callback(["code": "c", "state": query(url)["state"] ?? ""]) }

        let result = try await authorizer(world, agent).signIn(resource: mcpURL, challenge: MCPAuthChallenge(resourceMetadata: linearChallenge.resourceMetadata))

        XCTAssertEqual(world.urls("GET"), [
            "https://mcp.linear.app/.well-known/oauth-protected-resource/mcp",
            "https://auth.example.com/.well-known/oauth-authorization-server/tenant1",
            "https://auth.example.com/.well-known/openid-configuration/tenant1",
            "https://auth.example.com/tenant1/.well-known/openid-configuration",
        ])
        XCTAssertEqual(result.issuer, "https://auth.example.com/tenant1")
        XCTAssertNil(query(try XCTUnwrap(agent.authorizationURL))["scope"])
    }

    func testRejectsAuthorizationServerMetadataWhoseIssuerIsNotTheOneItWasFetchedFor() async throws {
        let world = try linearWorld()
        var forged = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("authorization-server")) as? [String: Any])
        forged["issuer"] = "https://honest.example"
        world.serve("GET", "https://mcp.linear.app/.well-known/oauth-authorization-server", try JSONSerialization.data(withJSONObject: forged))

        await assertSignInFails(.discoveryFailed, world)
        XCTAssertTrue(world.urls("POST").isEmpty)
    }

    func testRejectsProtectedResourceMetadataDescribingAnotherResource() async throws {
        let world = try linearWorld()
        world.serve("GET", "https://mcp.linear.app/.well-known/oauth-protected-resource/mcp", Data(#"{"resource":"https://other.example/mcp","authorization_servers":["https://mcp.linear.app"]}"#.utf8))

        await assertSignInFails(.discoveryFailed, world)
    }

    func testRefusesAServerThatDoesNotAdvertiseS256() async throws {
        let world = try linearWorld()
        var metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("authorization-server")) as? [String: Any])
        metadata.removeValue(forKey: "code_challenge_methods_supported")
        world.serve("GET", "https://mcp.linear.app/.well-known/oauth-authorization-server", try JSONSerialization.data(withJSONObject: metadata))
        let agent = FakeUserAgent()

        await assertSignInFails(.pkceUnsupported, world, agent)
        XCTAssertNil(agent.authorizationURL)
    }

    func testStopsWhenThereIsNoWayToGetAClientID() async throws {
        let world = try linearWorld()
        var metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("authorization-server")) as? [String: Any])
        metadata.removeValue(forKey: "registration_endpoint")
        metadata.removeValue(forKey: "client_id_metadata_document_supported")
        world.serve("GET", "https://mcp.linear.app/.well-known/oauth-authorization-server", try JSONSerialization.data(withJSONObject: metadata))

        await assertSignInFails(.noClientRegistration, world)
    }

    func testRejectsInsecureAuthorizationServerEndpoints() async throws {
        let world = try linearWorld()
        var metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("authorization-server")) as? [String: Any])
        metadata["token_endpoint"] = "http://mcp.linear.app/token"
        world.serve("GET", "https://mcp.linear.app/.well-known/oauth-authorization-server", try JSONSerialization.data(withJSONObject: metadata))

        await assertSignInFails(.discoveryFailed, world)
    }

    func testStateMismatchNeverReachesTheTokenEndpoint() async throws {
        let world = try linearWorld()
        let agent = FakeUserAgent()
        agent.respond = { _ in callback(["code": "stolen", "state": "someone-elses", "iss": issuer]) }

        await assertSignInFails(.stateMismatch, world, agent)
        XCTAssertFalse(world.urls("POST").contains("https://mcp.linear.app/token"))
    }

    func testIssuerMismatchNeverReachesTheTokenEndpoint() async throws {
        let world = try linearWorld()
        let agent = FakeUserAgent()
        agent.respond = { url in callback(["code": "c", "state": query(url)["state"] ?? "", "iss": "https://mcp.linear.app/"]) }

        await assertSignInFails(.issuerMismatch, world, agent)
        XCTAssertFalse(world.urls("POST").contains("https://mcp.linear.app/token"))
    }

    func testMissingIssuerIsRejectedWhenTheServerAdvertisesIt() async throws {
        let world = try linearWorld()
        let agent = FakeUserAgent()
        agent.respond = { url in callback(["code": "c", "state": query(url)["state"] ?? ""]) }

        await assertSignInFails(.issuerMismatch, world, agent)
        XCTAssertFalse(world.urls("POST").contains("https://mcp.linear.app/token"))
    }

    func testMissingIssuerIsAcceptedWhenTheServerDoesNotAdvertiseIt() async throws {
        let world = try linearWorld()
        var metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("authorization-server")) as? [String: Any])
        metadata.removeValue(forKey: "authorization_response_iss_parameter_supported")
        world.serve("GET", "https://mcp.linear.app/.well-known/oauth-authorization-server", try JSONSerialization.data(withJSONObject: metadata))
        let agent = FakeUserAgent()
        agent.respond = { url in callback(["code": "c", "state": query(url)["state"] ?? ""]) }

        let result = try await authorizer(world, agent).signIn(resource: mcpURL, challenge: linearChallenge)
        XCTAssertEqual(result.accessToken, "at-1")
    }

    func testAnErrorResponseFromTheWrongIssuerIsNotActedOn() async throws {
        let world = try linearWorld()
        let agent = FakeUserAgent()
        agent.respond = { url in callback(["error": "access_denied", "state": query(url)["state"] ?? "", "iss": "https://evil.example"]) }

        await assertSignInFails(.issuerMismatch, world, agent)
    }

    func testTheUserDecliningIsReportedAsDenied() async throws {
        let world = try linearWorld()
        let agent = FakeUserAgent()
        agent.respond = { url in callback(["error": "access_denied", "state": query(url)["state"] ?? "", "iss": issuer]) }

        await assertSignInFails(.denied, world, agent)
        XCTAssertFalse(world.urls("POST").contains("https://mcp.linear.app/token"))
    }

    func testRejectsATokenResponseThatIsNotABearerToken() async throws {
        let world = try linearWorld()
        world.route("POST", "https://mcp.linear.app/token") { _ in
            (200, [:], Data(#"{"access_token":"x","token_type":"mac"}"#.utf8))
        }
        await assertSignInFails(.tokenExchangeFailed, world)
    }
}

final class MCPOAuthSessionTests: XCTestCase {
    private final class Saved: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [MCPOAuthCredential] = []
        var all: [MCPOAuthCredential] { lock.withLock { values } }
        func add(_ value: MCPOAuthCredential) { lock.withLock { values.append(value) } }
    }

    func testAFreshTokenIsReturnedWithoutTouchingTheNetwork() async throws {
        let world = FakeWorld()
        let session = MCPOAuthSession(credential: credential(), performer: world, now: { clock })

        let token = try await session.accessToken()

        XCTAssertEqual(token, "at-1")
        XCTAssertTrue(world.requests.isEmpty)
    }

    func testAnExpiringTokenIsRefreshedWithTheResourceAndTheRotatedTokenIsPersisted() async throws {
        let world = FakeWorld()
        world.route("POST", "https://mcp.linear.app/token") { _ in tokenReply(access: "at-2", refresh: "rt-2", expiresIn: 7200) }
        let saved = Saved()
        let session = MCPOAuthSession(credential: credential(expiresIn: 30), performer: world, now: { clock }, persist: { saved.add($0) })

        let token = try await session.accessToken()

        XCTAssertEqual(token, "at-2")
        let request = form(try XCTUnwrap(world.requests.first))
        XCTAssertEqual(request["grant_type"], "refresh_token")
        XCTAssertEqual(request["refresh_token"], "rt-1")
        XCTAssertEqual(request["client_id"], "dcr-client")
        XCTAssertEqual(request["resource"], "https://mcp.linear.app/mcp")
        XCTAssertEqual(saved.all.map(\.refreshToken), ["rt-2"])
        XCTAssertEqual(saved.all.first?.expiresAt, clock.addingTimeInterval(7200))
    }

    func testARefreshResponseWithoutANewRefreshTokenKeepsTheOldOne() async throws {
        let world = FakeWorld()
        world.route("POST", "https://mcp.linear.app/token") { _ in tokenReply(access: "at-2", refresh: nil) }
        let session = MCPOAuthSession(credential: credential(expiresIn: 30), performer: world, now: { clock })

        _ = try await session.accessToken()

        let again = try await session.refreshed(after: "at-2")
        XCTAssertEqual(again, "at-2")
        XCTAssertEqual(world.requests.map { form($0)["refresh_token"] }, ["rt-1", "rt-1"])
    }

    func testAnotherCallerAlreadyRefreshingMeansNoSecondRefresh() async throws {
        let world = FakeWorld()
        world.route("POST", "https://mcp.linear.app/token") { _ in tokenReply(access: "at-2", refresh: "rt-2") }
        let session = MCPOAuthSession(credential: credential(), performer: world, now: { clock })

        let first = try await session.refreshed(after: "at-1")
        let second = try await session.refreshed(after: "at-1")

        XCTAssertEqual([first, second], ["at-2", "at-2"])
        XCTAssertEqual(world.urls("POST").count, 1)
    }

    func testARejectedRefreshTokenMeansSigningInAgain() async throws {
        let world = FakeWorld()
        world.route("POST", "https://mcp.linear.app/token") { _ in (400, [:], Data(#"{"error":"invalid_grant"}"#.utf8)) }
        let session = MCPOAuthSession(credential: credential(expiresIn: 30), performer: world, now: { clock })

        do {
            _ = try await session.accessToken()
            XCTFail("expected sign-in to be required")
        } catch {
            XCTAssertEqual(error as? MCPAuthError, .signInRequired)
        }
    }

    func testNoRefreshTokenMeansSigningInAgain() async throws {
        let session = MCPOAuthSession(credential: credential(refresh: nil), performer: FakeWorld(), now: { clock })
        do {
            _ = try await session.refreshed(after: "at-1")
            XCTFail("expected sign-in to be required")
        } catch {
            XCTAssertEqual(error as? MCPAuthError, .signInRequired)
        }
    }
}

final class MCPAuthorizedTransportTests: XCTestCase {
    private func gatedServer(_ world: FakeWorld, accepting token: @escaping @Sendable () -> String) {
        world.route("POST", "https://mcp.linear.app/mcp") { request in
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token())" else {
                return (401, ["WWW-Authenticate": #"Bearer resource_metadata="https://mcp.linear.app/.well-known/oauth-protected-resource/mcp", scope="read write""#], Data())
            }
            let message = try JSONValue(parsing: XCTUnwrap(request.httpBody))
            guard let id = message["id"] else { return (202, [:], Data()) }
            let result: JSONValue = switch message["method"]?.stringValue {
            case "initialize": .object(["protocolVersion": .string(MCPServer.protocolVersion), "serverInfo": .object(["name": .string("Linear")])])
            default: .object(["tools": .array([
                .object(["name": .string("list_issues"), "inputSchema": .object([:]), "annotations": .object(["readOnlyHint": .bool(true)])]),
                .object(["name": .string("save_issue"), "inputSchema": .object([:])]),
            ])])
            }
            return (200, ["Content-Type": "application/json"], try JSONValue.object(["jsonrpc": .string("2.0"), "id": id, "result": result]).data())
        }
    }

    func testAnUnauthenticatedServerSurfacesItsChallengeAndSignInUnlocksApprovalGatedTools() async throws {
        let world = try linearWorld()
        gatedServer(world) { "at-1" }

        let anonymous = try HTTPMCPTransport(endpoint: mcpURL, performer: world)
        let probe = MCPConnector(transport: anonymous, clientVersion: "test")
        var challenge: MCPAuthChallenge?
        do {
            try await probe.initialize()
            XCTFail("expected a 401")
        } catch let error as MCPUnauthorized {
            challenge = error.challenge
        }
        XCTAssertEqual(challenge, linearChallenge)

        let signedIn = try await authorizer(world, FakeUserAgent()).signIn(resource: mcpURL, challenge: try XCTUnwrap(challenge))
        let session = MCPOAuthSession(credential: signedIn, performer: world, now: { clock })
        let connector = MCPConnector(transport: try HTTPMCPTransport(endpoint: mcpURL, auth: session, performer: world), clientVersion: "test")
        try await connector.initialize()
        let tools = try await connector.makeExecutors(prefix: "Linear")

        XCTAssertEqual(tools.map { "\($0.spec.name) \($0.spec.tier)" }.sorted(), ["mcp.linear.list_issues green", "mcp.linear.save_issue orange"])
        let mcpRequests = world.requests.filter { $0.url == mcpURL }
        XCTAssertEqual(mcpRequests.dropFirst().compactMap { $0.value(forHTTPHeaderField: "Authorization") }.first, "Bearer at-1")
    }

    func testA401WithAStoredSessionRefreshesOnceAndRetries() async throws {
        let world = FakeWorld()
        let accepted = Locked("at-2")
        gatedServer(world) { accepted.value }
        world.route("POST", "https://mcp.linear.app/token") { _ in tokenReply(access: "at-2", refresh: "rt-2") }
        let session = MCPOAuthSession(credential: credential(), performer: world, now: { clock })
        let transport = try HTTPMCPTransport(endpoint: mcpURL, auth: session, performer: world)

        _ = try await transport.request(method: "initialize", params: nil)

        let sent = world.requests.filter { $0.url == mcpURL }.map { $0.value(forHTTPHeaderField: "Authorization") }
        XCTAssertEqual(sent, ["Bearer at-1", "Bearer at-2"])
        XCTAssertEqual(world.urls("POST").filter { $0.hasSuffix("/token") }.count, 1)
    }

    func testAStillRejectedTokenAfterRefreshSurfacesTheChallengeInsteadOfLooping() async throws {
        let world = FakeWorld()
        gatedServer(world) { "never" }
        world.route("POST", "https://mcp.linear.app/token") { _ in tokenReply(access: "at-2", refresh: "rt-2") }
        let session = MCPOAuthSession(credential: credential(), performer: world, now: { clock })
        let transport = try HTTPMCPTransport(endpoint: mcpURL, auth: session, performer: world)

        do {
            _ = try await transport.request(method: "initialize", params: nil)
            XCTFail("expected a 401")
        } catch let error as MCPUnauthorized {
            XCTAssertEqual(error.challenge, linearChallenge)
        }
        XCTAssertEqual(world.requests.filter { $0.url == mcpURL }.count, 2)
    }

    func testARevokedRefreshTokenSurfacesAsUnauthorized() async throws {
        let world = FakeWorld()
        gatedServer(world) { "never" }
        world.route("POST", "https://mcp.linear.app/token") { _ in (400, [:], Data(#"{"error":"invalid_grant"}"#.utf8)) }
        let session = MCPOAuthSession(credential: credential(), performer: world, now: { clock })
        let transport = try HTTPMCPTransport(endpoint: mcpURL, auth: session, performer: world)

        do {
            _ = try await transport.request(method: "initialize", params: nil)
            XCTFail("expected a 401")
        } catch is MCPUnauthorized {}
    }

    func testStaticBearerHeadersStillWork() async throws {
        let world = FakeWorld()
        gatedServer(world) { "static-key" }
        let transport = try HTTPMCPTransport(endpoint: mcpURL, headers: ["Authorization": "Bearer static-key"], performer: world)

        let result = try await transport.request(method: "initialize", params: nil)

        XCTAssertEqual(result["serverInfo"]?["name"]?.stringValue, "Linear")
    }
}

private final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
}

final class LoopbackAuthorizationUserAgentTests: XCTestCase {
    func testBindsToLoopbackAndReturnsTheCallbackIgnoringStrayRequests() async throws {
        let agent = LoopbackMCPAuthorizationUserAgent(open: { url in
            let redirect = query(url)["redirect_uri"]!
            Task.detached {
                _ = try? await URLSession.shared.data(from: URL(string: redirect.replacingOccurrences(of: "/callback", with: "/favicon.ico"))!)
                _ = try? await URLSession.shared.data(from: URL(string: redirect + "?code=abc&state=xyz&iss=i")!)
            }
            return true
        }, timeout: .seconds(10))

        let received = try await agent.authorize { redirect in
            XCTAssertEqual(redirect.host, "127.0.0.1")
            XCTAssertEqual(redirect.path, "/callback")
            XCTAssertNotNil(redirect.port)
            var parts = URLComponents(string: "https://as.example/authorize")!
            parts.queryItems = [.init(name: "redirect_uri", value: redirect.absoluteString)]
            return parts.url!
        }

        XCTAssertEqual(received.path, "/callback")
        XCTAssertEqual(query(received), ["code": "abc", "state": "xyz", "iss": "i"])
    }

    func testReportsWhenNoBrowserCouldBeOpened() async {
        let agent = LoopbackMCPAuthorizationUserAgent(open: { _ in false }, timeout: .seconds(10))
        do {
            _ = try await agent.authorize { _ in URL(string: "https://as.example/authorize")! }
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? MCPAuthError, .browserUnavailable)
        }
    }

    func testGivesUpWhenNobodyComesBack() async {
        let agent = LoopbackMCPAuthorizationUserAgent(open: { _ in true }, timeout: .milliseconds(200))
        do {
            _ = try await agent.authorize { _ in URL(string: "https://as.example/authorize")! }
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? MCPAuthError, .timedOut)
        }
    }
}
