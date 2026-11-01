import PerryBrain
import PerryCore
@testable import Perry
import XCTest

@MainActor
final class CustomConnectorsTests: XCTestCase {
    private var directory: URL!
    private var keychain: KeychainStore!

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

    private var fakeServerPath: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Packages/PerryBrain/Tests/PerryBrainTests/Fixtures/fake-mcp-server.py").path
    }

    private var fakeServer: CustomConnector.Endpoint {
        .command("/usr/bin/python3 -u '\(fakeServerPath)'")
    }

    func testCommandKeyReachesTheServerOnlyThroughItsVariableAndLeavesWithRemove() async throws {
        let connectors = CustomConnectors(directory: directory, host: PerryToolHost(executors: []), keychain: keychain)
        let gated = CustomConnector.Endpoint.command("/bin/sh -c '[ ${#NOTES_KEY} -eq 6 ] && exec /usr/bin/python3 -u \"\(fakeServerPath)\"'")

        let status = await connectors.add(CustomConnector(name: "Keyed", endpoint: gated, secret: .environment("NOTES_KEY")), secret: "s3cret")

        XCTAssertEqual(status, .ready(toolCount: 2))
        let saved = try String(contentsOf: directory.appendingPathComponent("connectors.json"), encoding: .utf8)
        XCTAssertFalse(saved.contains("s3cret"))
        XCTAssertEqual(try keychain.accounts().count, 1)

        connectors.remove(try XCTUnwrap(connectors.connectors.first?.id))
        XCTAssertEqual(try keychain.accounts(), [])
    }

    func testServerThatStopsDropsItsToolsAndCanReconnect() async throws {
        let host = PerryToolHost(executors: [])
        let connectors = CustomConnectors(directory: directory, host: host, keychain: keychain)
        let dying = CustomConnector.Endpoint.command("{ sleep 2; kill $$; } & exec /usr/bin/python3 -u '\(fakeServerPath)'")

        let status = await connectors.add(CustomConnector(name: "Dying", endpoint: dying))
        XCTAssertEqual(status, .ready(toolCount: 2))
        let id = try XCTUnwrap(connectors.connectors.first?.id)

        for _ in 0..<100 where connectors.status[id] == .ready(toolCount: 2) {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(connectors.status[id], .failed("The server stopped."))
        XCTAssertTrue(host.specs(for: .agent).isEmpty)
        XCTAssertEqual(connectors.connectors.map(\.name), ["Dying"])

        connectors.reconnect(id)
        for _ in 0..<100 where connectors.status[id] != .ready(toolCount: 2) {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(connectors.status[id], .ready(toolCount: 2))
        connectors.forgetAll()
    }

    func testCommandKeyWithoutAVariableIsRejectedBeforeAnythingIsStored() async throws {
        let connectors = CustomConnectors(directory: directory, host: PerryToolHost(executors: []), keychain: keychain)

        let status = await connectors.add(CustomConnector(name: "Keyed", endpoint: fakeServer, secret: .environment("not a name")), secret: "s3cret")

        XCTAssertEqual(status, .failed("Name the variable the server reads its key from, like API_KEY."))
        XCTAssertEqual(try keychain.accounts(), [])
        XCTAssertTrue(connectors.connectors.isEmpty)
    }

    func testAddedCommandConnectorExposesApprovalGatedToolsAndPersists() async throws {
        let host = PerryToolHost(executors: [])
        let connectors = CustomConnectors(directory: directory, host: host)

        let status = await connectors.add(CustomConnector(name: "Fake Notes", endpoint: fakeServer))

        XCTAssertEqual(status, .ready(toolCount: 2))
        XCTAssertEqual(host.specs(for: .agent).map(\.name), ["mcp.fake-notes.mutate", "mcp.fake-notes.search"])
        XCTAssertEqual(host.spec(named: "mcp.fake-notes.mutate")?.tier, .orange)
        XCTAssertEqual(CustomConnectors(directory: directory, host: PerryToolHost(executors: [])).connectors.map(\.name), ["Fake Notes"])

        let id = try XCTUnwrap(connectors.connectors.first?.id)
        connectors.remove(id)
        XCTAssertTrue(host.specs(for: .agent).isEmpty)
        XCTAssertTrue(CustomConnectors(directory: directory, host: PerryToolHost(executors: [])).connectors.isEmpty)
    }

    func testSilentServerTimesOutAndIsNotSaved() async {
        let host = PerryToolHost(executors: [])
        let connectors = CustomConnectors(directory: directory, host: host, timeout: .seconds(1))

        let status = await connectors.add(CustomConnector(name: "Silent", endpoint: .command("sleep 30")))

        XCTAssertEqual(status, .failed("The server didn’t answer within 1 second."))
        XCTAssertTrue(connectors.connectors.isEmpty)
        XCTAssertTrue(CustomConnectors(directory: directory, host: host).connectors.isEmpty)
    }

    func testDuplicateNamesAreRejected() async {
        let connectors = CustomConnectors(directory: directory, host: PerryToolHost(executors: []))
        _ = await connectors.add(CustomConnector(name: "Fake Notes", endpoint: fakeServer))

        let duplicate = await connectors.add(CustomConnector(name: "fake notes", endpoint: fakeServer))

        XCTAssertEqual(duplicate, .failed("A connector called fake notes already exists."))
        let lookalike = await connectors.add(CustomConnector(name: "fake_notes", endpoint: fakeServer))
        XCTAssertEqual(lookalike, .failed("That name is too close to Fake Notes. Pick another."))
        XCTAssertEqual(connectors.connectors.count, 1)
        connectors.disconnectAll()
    }

    private func unwritableDirectory() throws -> URL {
        let blocker = directory.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        return blocker
    }

    func testAConnectorThatCannotBeSavedIsDisconnectedForgottenAndItsKeyCleared() async throws {
        let backend = FlakyCredentialBackend()
        let host = PerryToolHost(executors: [])
        let connectors = CustomConnectors(directory: try unwritableDirectory(), host: host, keychain: backend)

        let status = await connectors.add(CustomConnector(name: "Keyed", endpoint: fakeServer, secret: .environment("API_KEY")), secret: "s3cret")

        XCTAssertEqual(status, .failed("I couldn’t save the connector."))
        XCTAssertTrue(connectors.connectors.isEmpty)
        XCTAssertTrue(host.specs(for: .agent).isEmpty)
        XCTAssertEqual(backend.accounts, [])
    }

    func testAFailedAddAlsoSaysWhenItsKeyCouldNotBeCleared() async throws {
        let backend = FlakyCredentialBackend()
        let connectors = CustomConnectors(directory: try unwritableDirectory(), host: PerryToolHost(executors: []), keychain: backend)
        backend.refuse(deletes: true)

        let status = await connectors.add(CustomConnector(name: "Keyed", endpoint: fakeServer, secret: .environment("API_KEY")), secret: "s3cret")

        XCTAssertEqual(status, .failed("I couldn’t save the connector. I couldn’t clear its key from your Keychain."))
        XCTAssertEqual(backend.accounts.count, 1)
    }

    func testRemovingAConnectorWhoseKeyStaysInTheKeychainSaysSo() async throws {
        let backend = FlakyCredentialBackend()
        let connectors = CustomConnectors(directory: directory, host: PerryToolHost(executors: []), keychain: backend)
        _ = await connectors.add(CustomConnector(name: "Keyed", endpoint: fakeServer, secret: .environment("API_KEY")), secret: "s3cret")
        let id = try XCTUnwrap(connectors.connectors.first?.id)
        backend.refuse(deletes: true)

        let failure = connectors.remove(id)

        XCTAssertEqual(failure, "I removed the connector, but couldn’t clear its key from your Keychain.")
        XCTAssertTrue(connectors.connectors.isEmpty)
        XCTAssertEqual(backend.accounts.count, 1)
    }

    func testRemovingAConnectorWhoseListCannotBeSavedSaysItMayComeBack() async throws {
        let backend = FlakyCredentialBackend()
        let connectors = CustomConnectors(directory: directory, host: PerryToolHost(executors: []), keychain: backend)
        _ = await connectors.add(CustomConnector(name: "Fake Notes", endpoint: fakeServer))
        let id = try XCTUnwrap(connectors.connectors.first?.id)
        try FileManager.default.removeItem(at: directory)
        try Data().write(to: directory)

        let failure = connectors.remove(id)

        XCTAssertEqual(failure, "I couldn’t save the change. The connector may come back when Perry restarts.")
        XCTAssertTrue(connectors.connectors.isEmpty)
    }

    func testRemovingReportsBothASaveFailureAndAKeyLeftInTheKeychain() async throws {
        let backend = FlakyCredentialBackend()
        let connectors = CustomConnectors(directory: directory, host: PerryToolHost(executors: []), keychain: backend)
        _ = await connectors.add(CustomConnector(name: "Keyed", endpoint: fakeServer, secret: .environment("API_KEY")), secret: "s3cret")
        let id = try XCTUnwrap(connectors.connectors.first?.id)
        backend.refuse(deletes: true)
        try FileManager.default.removeItem(at: directory)
        try Data().write(to: directory)

        let failure = connectors.remove(id)

        XCTAssertEqual(failure, "I couldn’t save the change. The connector may come back when Perry restarts. Its key is also still in your Keychain.")
    }

    func testRemotePlainHTTPIsRejectedBeforeTheTokenIsStored() async throws {
        let connectors = CustomConnectors(directory: directory, host: PerryToolHost(executors: []), keychain: keychain)

        let status = await connectors.add(CustomConnector(name: "Remote", endpoint: .url(URL(string: "http://example.com/mcp")!)), secret: "token")

        XCTAssertEqual(status, .failed("Use an https address. Plain http only works for servers on this Mac."))
        XCTAssertTrue(connectors.connectors.isEmpty)
        XCTAssertEqual(try keychain.accounts(), [])
    }
}
