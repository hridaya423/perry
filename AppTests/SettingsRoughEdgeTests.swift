import AuthenticationServices
import Foundation
import PerryBrain
import PerryCore
import XCTest
@testable import Perry

private final class HangingAgent: MCPAuthorizationUserAgent, @unchecked Sendable {
    private let lock = NSLock()
    private var began = false

    var hasBegun: Bool { lock.withLock { began } }

    func authorize(_ makeAuthorizationURL: @Sendable (URL) async throws -> URL) async throws -> URL {
        lock.withLock { began = true }
        try await Task.sleep(for: .seconds(60))
        throw OAuthError.cancelled
    }
}

private final class MemoryBackend: OAuthCredentialStoreBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func readCredential(account: String) throws -> String? { lock.withLock { values[account] } }
    func save(_ secret: String, account: String) throws { lock.withLock { values[account] = secret } }
    func deleteCredential(account: String) throws { lock.withLock { values[account] = nil } }
}

@MainActor
final class SettingsRoughEdgeTests: XCTestCase {
    private func makeConnections(agent: HangingAgent) -> (IntegrationConnections, RemoteIntegrationDefinition) {
        let suite = "dev.perry.tests.rough-edges.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let permissions = RemoteIntegrationPermissionStore(suiteName: suite)
        let coordinator = OAuthCoordinator(
            credentialStore: OAuthCredentialStore(backend: MemoryBackend()),
            makeSessionAgent: { _ in agent },
            transport: { _ in throw URLError(.cancelled) }
        )
        let client = RemoteIntegrationClient(
            keychain: KeychainStore(service: "dev.perry.tests.rough-edges.\(UUID().uuidString)"),
            transport: { _ in throw URLError(.cancelled) },
            permissionStore: permissions
        )
        let connections = IntegrationConnections(
            oauth: coordinator,
            client: client,
            permissions: permissions,
            bundled: BundledOAuthClients(infoDictionary: ["PerryOAuthLinearClientID": "lin-id"])
        )
        return (connections, RemoteIntegrationDefinition.catalog.first { $0.id == "linear" }!)
    }

    func testCancellingASignInMidFlowReturnsTheRowToIdle() async throws {
        let agent = HangingAgent()
        let (connections, linear) = makeConnections(agent: agent)
        let finished = expectation(description: "sign-in ended")
        var outcome: Result<Void, Error>?
        connections.connect(linear) { result in
            outcome = result
            finished.fulfill()
        }
        let deadline = Date().addingTimeInterval(5)
        while !agent.hasBegun, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(agent.hasBegun)

        connections.cancel()
        await fulfillment(of: [finished], timeout: 5)

        guard case .failure(let error)? = outcome else { return XCTFail("expected a failure") }
        XCTAssertEqual(IntegrationOperationState.resulting(from: error), .idle)
    }

    func testStateMappingTreatsCancellationAsIdleAndExpiryAsReconnect() {
        XCTAssertEqual(IntegrationOperationState.resulting(from: CancellationError()), .idle)
        XCTAssertEqual(IntegrationOperationState.resulting(from: OAuthError.cancelled), .idle)
        XCTAssertEqual(IntegrationOperationState.resulting(from: OAuthError.refreshFailed(400)), .needsReconnect)
        XCTAssertEqual(IntegrationOperationState.resulting(from: RemoteIntegrationError.authenticationRequired), .needsReconnect)
        XCTAssertEqual(
            IntegrationOperationState.resulting(from: RemoteIntegrationError.providerReturned("nope")),
            .failed("nope")
        )
    }

    func testTestingAnIntegrationWithoutACredentialAsksToReconnect() async throws {
        let (connections, linear) = makeConnections(agent: HangingAgent())
        let finished = expectation(description: "test ended")
        var outcome: Result<String, Error>?
        connections.test(linear) { result in
            outcome = result
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 5)

        guard case .failure(let error)? = outcome else { return XCTFail("expected a failure") }
        XCTAssertEqual(IntegrationOperationState.resulting(from: error), .needsReconnect)
    }

    func testClosingTheSystemSignInSheetBecomesTheCancelledError() {
        let closed = NSError(
            domain: ASWebAuthenticationSessionErrorDomain,
            code: ASWebAuthenticationSessionError.canceledLogin.rawValue
        )
        let mapped = WebAuthenticationSessionUserAgent.normalized(closed)
        XCTAssertTrue(mapped is OAuthError)
        XCTAssertEqual(IntegrationOperationState.resulting(from: mapped), .idle)

        let other = NSError(domain: ASWebAuthenticationSessionErrorDomain, code: ASWebAuthenticationSessionError.presentationContextNotProvided.rawValue)
        XCTAssertFalse(WebAuthenticationSessionUserAgent.normalized(other) is OAuthError)
    }

    func testProfileFieldsSaveOnlyWhenTheyChanged() {
        XCTAssertFalse(YouSettingsPage.isUnsaved("Name", profile: ["Name": "Ada"], saved: ["Name": "Ada"]))
        XCTAssertFalse(YouSettingsPage.isUnsaved("Name", profile: [:], saved: ["Name": ""]))
        XCTAssertTrue(YouSettingsPage.isUnsaved("Name", profile: ["Name": "Ada L"], saved: ["Name": "Ada"]))
        XCTAssertTrue(YouSettingsPage.isUnsaved("Work", profile: ["Work": "Math"], saved: [:]))
    }

    func testAChosenModelThatIsNotDownloadedOffersADownloadAndNamesTheOneRunning() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = PerryPreferences.localModel
        defer {
            PerryPreferences.localModel = previous
            try? FileManager.default.removeItem(at: directory)
        }
        let large = ModelFit.lineup[0]
        let small = ModelFit.lineup[1]
        let installedDirectory = directory.appendingPathComponent(small.id, isDirectory: true)
        try FileManager.default.createDirectory(at: installedDirectory, withIntermediateDirectories: true)
        for file in small.files {
            XCTAssertTrue(FileManager.default.createFile(atPath: installedDirectory.appendingPathComponent(file).path, contents: Data()))
        }
        PerryPreferences.localModel = large.id
        let local = LocalBrain(engine: nil, modelsDirectory: directory, benchURL: directory.appendingPathComponent("bench.json"))

        XCTAssertEqual(local.phase, .ready)
        XCTAssertEqual(local.installed?.id, small.id)
        XCTAssertEqual(local.substitute(for: large)?.id, small.id)
        XCTAssertNil(local.substitute(for: small))
        XCTAssertEqual(
            LocalBrainView.runningNote(chosen: large, running: small, offers: []),
            "Using \(LocalModelList.modelName(small)) until \(LocalModelList.modelName(large)) is downloaded."
        )
    }

    func testGigabyteFiguresUseTheCurrentLocale() {
        XCTAssertEqual(LocalBrainView.gigabytes(4.5), 4.5.formatted(.number.precision(.fractionLength(1))))
        XCTAssertEqual(LocalBrainView.gigabytes(8, digits: 0), "8")
    }
}
