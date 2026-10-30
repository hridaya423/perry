import Foundation
import XCTest
import PerryCore
import PerryGuide
import PerryRuntimes
@testable import Perry

final class RemoteIntegrationClientTests: XCTestCase {
    func testDeniedCapabilityDoesNotReachTransport() async throws {
        let definition = RemoteIntegrationDefinition.catalog.first { $0.id == "slack" }!
        let capture = RequestCapture()
        let client = RemoteIntegrationClient(
            keychain: KeychainStore(service: "dev.perry.tests.integration.\(UUID().uuidString)"),
            transport: { request in
                await capture.append(request)
                throw URLError(.cancelled)
            }
        )

        do {
            _ = try await client.read(definition: definition, path: "/admin.users")
            XCTFail("expected unsupported capability to fail")
        } catch let error as RemoteIntegrationError {
            XCTAssertEqual(error, .capabilityDenied)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let requests = await capture.all()
        XCTAssertTrue(requests.isEmpty)
    }

    func testCredentialQueryCannotReachProviderTransport() async throws {
        let definition = RemoteIntegrationDefinition.catalog.first { $0.id == "slack" }!
        let capture = RequestCapture()
        let client = RemoteIntegrationClient(
            keychain: KeychainStore(service: "dev.perry.tests.integration.\(UUID().uuidString)"),
            transport: { request in
                await capture.append(request)
                throw URLError(.cancelled)
            }
        )

        do {
            _ = try await client.read(definition: definition, path: "/auth.test?access_token=leaked")
            XCTFail("expected credential-like query to fail")
        } catch let error as RemoteIntegrationError {
            XCTAssertEqual(error, .capabilityDenied)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let requests = await capture.all()
        XCTAssertTrue(requests.isEmpty)
    }

    func testWriteScopeEnforcementPrecedesTransport() async throws {
        let definition = RemoteIntegrationDefinition.catalog.first { $0.id == "slack" }!
        let suiteName = "dev.perry.tests.remote-write-scope.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let permissionStore = RemoteIntegrationPermissionStore(suiteName: suiteName)
        let keychain = KeychainStore(service: "dev.perry.tests.integration.\(UUID().uuidString)")
        let capture = RequestCapture()
        defer {
            try? keychain.deleteChecked(account: definition.credentialAccount)
            defaults.removePersistentDomain(forName: suiteName)
        }
        permissionStore.setWritesEnabled(true, for: definition)
        try await OAuthCredentialStore(keychain: keychain).save(
            StoredOAuthCredential(
                token: OAuthToken(
                    accessToken: "xoxp-test",
                    refreshToken: "refresh",
                    expiresAt: Date.distantPast
                ),
                clientID: "client",
                clientSecret: nil,
                grantedScopes: ["channels:read"]
            ),
            for: definition
        )
        let client = RemoteIntegrationClient(
            keychain: keychain,
            transport: { request in
                await capture.append(request)
                throw URLError(.cancelled)
            },
            permissionStore: permissionStore
        )
        let write = try XCTUnwrap(
            RemoteIntegrationWriteRequest(
                parameters: .slackSendMessage(channel: "C1", text: "hello")
            )
        )
        let approval = RemoteIntegrationApproval(
            stepID: "step",
            integrationID: definition.id,
            operation: write.operation,
            tier: .orange,
            approvedScopes: write.requiredScopes,
            request: write
        )
        XCTAssertTrue(definition.allowsRemoteWrite(write))
        XCTAssertTrue(approval.matches(stepID: nil, definition: definition, request: write))

        do {
            _ = try await client.request(definition: definition, write: write, approval: approval)
            XCTFail("expected missing write scope to fail")
        } catch let error as RemoteIntegrationError {
            XCTAssertEqual(error, .scopeDenied)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let requests = await capture.all()
        XCTAssertTrue(requests.isEmpty)
    }

    func testDisabledWriteIsRejectedBeforeCredentialValidation() async throws {
        let definition = RemoteIntegrationDefinition.catalog.first { $0.id == "slack" }!
        let suiteName = "dev.perry.tests.remote-writes-disabled-client.\(UUID().uuidString)"
        let permissionStore = RemoteIntegrationPermissionStore(suiteName: suiteName)
        let capture = RequestCapture()
        let client = RemoteIntegrationClient(
            keychain: KeychainStore(service: "dev.perry.tests.integration.\(UUID().uuidString)"),
            transport: { request in
                await capture.append(request)
                throw URLError(.cancelled)
            },
            permissionStore: permissionStore
        )
        let write = try XCTUnwrap(
            RemoteIntegrationWriteRequest(
                parameters: .slackSendMessage(channel: "C1", text: "hello")
            )
        )
        let approval = RemoteIntegrationApproval(
            stepID: "step",
            integrationID: definition.id,
            operation: write.operation,
            tier: .orange,
            approvedScopes: write.requiredScopes,
            request: write
        )

        do {
            _ = try await client.request(definition: definition, write: write, approval: approval)
            XCTFail("expected disabled write to fail")
        } catch let error as RemoteIntegrationError {
            XCTAssertEqual(error, .writesDisabled)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let requests = await capture.all()
        XCTAssertTrue(requests.isEmpty)
    }

    func testWriteApprovalCannotBeReusedForDifferentPayload() async throws {
        let definition = RemoteIntegrationDefinition.catalog.first { $0.id == "slack" }!
        let suiteName = "dev.perry.tests.remote-write-approval.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let permissionStore = RemoteIntegrationPermissionStore(suiteName: suiteName)
        let keychain = KeychainStore(service: "dev.perry.tests.integration.\(UUID().uuidString)")
        let capture = RequestCapture()
        defer {
            try? keychain.deleteChecked(account: definition.credentialAccount)
            defaults.removePersistentDomain(forName: suiteName)
        }
        permissionStore.setWritesEnabled(true, for: definition)
        try await OAuthCredentialStore(keychain: keychain).save(
            StoredOAuthCredential(
                token: OAuthToken(
                    accessToken: "xoxp-test",
                    refreshToken: "refresh",
                    expiresAt: Date.distantPast
                ),
                clientID: "client",
                clientSecret: nil,
                grantedScopes: ["chat:write"]
            ),
            for: definition
        )
        let client = RemoteIntegrationClient(
            keychain: keychain,
            transport: { request in
                await capture.append(request)
                throw URLError(.cancelled)
            },
            permissionStore: permissionStore
        )
        let approvedWrite = try XCTUnwrap(
            RemoteIntegrationWriteRequest(
                parameters: .slackSendMessage(channel: "C1", text: "approved")
            )
        )
        let differentWrite = try XCTUnwrap(
            RemoteIntegrationWriteRequest(
                parameters: .slackSendMessage(channel: "C2", text: "unapproved")
            )
        )
        let approval = RemoteIntegrationApproval(
            stepID: "step",
            integrationID: definition.id,
            operation: approvedWrite.operation,
            tier: .orange,
            approvedScopes: approvedWrite.requiredScopes,
            request: approvedWrite
        )

        do {
            _ = try await client.request(definition: definition, write: differentWrite, approval: approval)
            XCTFail("expected approval mismatch to fail")
        } catch let error as RemoteIntegrationError {
            XCTAssertEqual(error, .capabilityDenied)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let requests = await capture.all()
        XCTAssertTrue(requests.isEmpty)
    }

    func testDisablingWritesDuringRefreshPreventsDispatchAndUnauthorizedRetry() async throws {
        for initiallyExpired in [true, false] {
            let definition = try XCTUnwrap(RemoteIntegrationDefinition.catalog.first { $0.id == "slack" })
            let suiteName = "dev.perry.tests.refresh-write-revocation.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            let permissionStore = RemoteIntegrationPermissionStore(suiteName: suiteName)
            let keychain = KeychainStore(service: "dev.perry.tests.integration.\(UUID().uuidString)")
            let capture = RequestCapture()
            defer {
                do {
                    try keychain.deleteChecked(account: definition.credentialAccount)
                } catch {
                    XCTFail("Could not erase fixture credential: \(error)")
                }
                defaults.removePersistentDomain(forName: suiteName)
            }
            permissionStore.setWritesEnabled(true, for: definition)
            try await OAuthCredentialStore(keychain: keychain).save(
                StoredOAuthCredential(
                    token: OAuthToken(
                        accessToken: "fixture-token", refreshToken: "fixture-refresh",
                        expiresAt: initiallyExpired ? Date.distantPast : Date.distantFuture
                    ),
                    clientID: "fixture-client", clientSecret: nil, grantedScopes: ["chat:write"]
                ),
                for: definition
            )
            let client = RemoteIntegrationClient(
                keychain: keychain,
                transport: { request in
                    await capture.append(request)
                    if request.url == definition.tokenURL {
                        permissionStore.setWritesEnabled(false, for: definition)
                        return (
                            Data(#"{"access_token":"fixture-fresh","token_type":"Bearer","expires_in":3600}"#.utf8),
                            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                        )
                    }
                    let requestCount = await capture.apiRequestCount(excluding: definition.tokenURL)
                    return (
                        Data(#"{"ok":true}"#.utf8),
                        HTTPURLResponse(url: request.url!, statusCode: !initiallyExpired && requestCount == 1 ? 401 : 200,
                                        httpVersion: nil, headerFields: nil)!
                    )
                },
                permissionStore: permissionStore
            )
            let write = try XCTUnwrap(RemoteIntegrationWriteRequest(
                parameters: .slackSendMessage(channel: "fixture-channel", text: "fixture message")
            ))
            let approval = RemoteIntegrationApproval(
                stepID: "fixture-step",
                integrationID: definition.id,
                operation: write.operation,
                tier: .orange,
                approvedScopes: write.requiredScopes,
                request: write
            )

            do {
                _ = try await client.request(definition: definition, write: write, approval: approval)
                XCTFail("A revoked write reached the provider after refresh")
            } catch let error as RemoteIntegrationError {
                XCTAssertEqual(error, .writesDisabled)
            }

            let requests = await capture.all()
            XCTAssertEqual(requests.filter { $0.url == definition.tokenURL }.count, 1)
            XCTAssertEqual(requests.filter { $0.url != definition.tokenURL }.count, initiallyExpired ? 0 : 1)
        }
    }

    func testClientBuildsProviderURLAndBearerRequest() async throws {
        let definition = RemoteIntegrationDefinition.catalog.first { $0.id == "slack" }!
        let keychain = KeychainStore(service: "dev.perry.tests.integration.\(UUID().uuidString)")
        let credentialStore = OAuthCredentialStore(keychain: keychain)
        let capture = RequestCapture()
        defer { try? keychain.deleteChecked(account: definition.credentialAccount) }
        try await credentialStore.save(
            StoredOAuthCredential(
                token: OAuthToken(accessToken: "xoxp-test", tokenType: "user"),
                clientID: "client",
                clientSecret: nil
            ),
            for: definition
        )
        let client = RemoteIntegrationClient(
            keychain: keychain,
            transport: { request in
                await capture.append(request)
                return (
                    Data(#"{"ok":true,"team":"Perry"}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            }
        )

        _ = try await client.read(definition: definition, path: "/conversations.list?limit=1&exclude_archived=true")
        let capturedRequest = await capture.last()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://slack.com/api/conversations.list?limit=1&exclude_archived=true")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer xoxp-test")
        XCTAssertEqual(request.httpMethod, "GET")
    }

    func testClientRefreshesOnceAfterUnauthorizedResponse() async throws {
        let definition = RemoteIntegrationDefinition.catalog.first { $0.id == "linear" }!
        let keychain = KeychainStore(service: "dev.perry.tests.integration.\(UUID().uuidString)")
        let credentialStore = OAuthCredentialStore(keychain: keychain)
        let capture = RequestCapture()
        defer { try? keychain.deleteChecked(account: definition.credentialAccount) }
        try await credentialStore.save(
            StoredOAuthCredential(
                token: OAuthToken(accessToken: "expired", refreshToken: "refresh", tokenType: "Bearer"),
                clientID: "client",
                clientSecret: nil
            ),
            for: definition
        )
        let client = RemoteIntegrationClient(
            keychain: keychain,
            transport: { request in
                await capture.append(request)
                if request.url == definition.tokenURL {
                    return (
                        Data(#"{"access_token":"fresh","token_type":"Bearer","expires_in":3600}"#.utf8),
                        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    )
                }
                let apiRequestCount = await capture.apiRequestCount(excluding: definition.tokenURL)
                let status = apiRequestCount == 1 ? 401 : 200
                return (
                    Data(#"{"data":{"viewer":{"id":"1","name":"Perry"}}}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                )
            }
        )

        _ = try await client.preview(definition: definition, action: definition.quickActions[0])
        let requests = await capture.all()
        XCTAssertEqual(requests.filter { $0.url == definition.tokenURL }.count, 1)
        XCTAssertEqual(requests.filter { $0.url?.path == "/graphql" }.count, 2)
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer fresh")
    }

    func testClientRejectsPlaintextRemoteEndpointBeforeTransport() async throws {
        let source = RemoteIntegrationDefinition.catalog.first { $0.id == "slack" }!
        let definition = RemoteIntegrationDefinition(
            descriptor: source.descriptor,
            baseURL: URL(string: "http://api.example.com")!,
            authorizationURL: source.authorizationURL,
            tokenURL: source.tokenURL,
            scopes: source.scopes,
            writesEnabledByDefault: source.writesEnabledByDefault,
            oauthStyle: source.oauthStyle,
            authorizationParameters: source.authorizationParameters
        )
        let client = RemoteIntegrationClient(
            transport: { _ in
                XCTFail("unsafe endpoint must not reach transport")
                throw URLError(.badURL)
            }
        )

        do {
            _ = try await client.read(definition: definition, path: "/auth.test")
            XCTFail("expected unsafe endpoint to fail")
        } catch let error as NetworkEndpointError {
            XCTAssertEqual(error, .insecureRemoteEndpoint)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    @MainActor
    func testCredentialStoreKeepsBackendOffMainActor() async throws {
        let definition = RemoteIntegrationDefinition.catalog.first { $0.id == "slack" }!
        let backend = RecordingCredentialBackend()
        let store = OAuthCredentialStore(backend: backend)
        let credential = StoredOAuthCredential(
            token: OAuthToken(accessToken: "test-token"),
            clientID: "client",
            clientSecret: "secret"
        )

        try await store.save(credential, for: definition)
        let saved = try await store.load(for: definition)
        try await store.delete(for: definition)
        let deleted = try await store.load(for: definition)

        XCTAssertEqual(saved, credential)
        XCTAssertNil(deleted)
        XCTAssertFalse(backend.wasCalledOnMainThread)
    }

    func testMalformedCredentialFailsClosedBeforeProviderTransport() async throws {
        let definition = RemoteIntegrationDefinition.catalog.first { $0.id == "slack" }!
        let keychain = KeychainStore(service: "dev.perry.tests.integration.\(UUID().uuidString)")
        let capture = RequestCapture()
        defer { try? keychain.deleteChecked(account: definition.credentialAccount) }
        try keychain.save("not-json", account: definition.credentialAccount)
        let client = RemoteIntegrationClient(
            keychain: keychain,
            transport: { request in
                await capture.append(request)
                throw URLError(.cancelled)
            }
        )

        do {
            _ = try await client.read(definition: definition, path: "/conversations.list?limit=1")
            XCTFail("expected malformed credential to fail")
        } catch let error as OAuthCredentialStoreError {
            XCTAssertEqual(error, .malformedCredential(definition.credentialAccount))
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let requests = await capture.all()
        XCTAssertTrue(requests.isEmpty)
    }

    private actor RequestCapture {
        private var requests: [URLRequest] = []

        func append(_ request: URLRequest) {
            requests.append(request)
        }

        func last() -> URLRequest? {
            requests.last
        }

        func all() -> [URLRequest] {
            requests
        }

        func apiRequestCount(excluding tokenURL: URL) -> Int {
            requests.filter { $0.url != tokenURL }.count
        }
    }
}

private final class RecordingCredentialBackend: OAuthCredentialStoreBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private(set) var wasCalledOnMainThread = false

    func readCredential(account: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        wasCalledOnMainThread = wasCalledOnMainThread || Thread.isMainThread
        return values[account]
    }

    func save(_ secret: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        wasCalledOnMainThread = wasCalledOnMainThread || Thread.isMainThread
        values[account] = secret
    }

    func deleteCredential(account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        wasCalledOnMainThread = wasCalledOnMainThread || Thread.isMainThread
        values[account] = nil
    }
}

private extension RemoteIntegrationClient {
    func read(definition: RemoteIntegrationDefinition, path: String) async throws -> String {
        try await preview(definition: definition, action: RemoteIntegrationQuickAction(id: "probe", title: "Probe", path: path))
    }
}
