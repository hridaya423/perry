import CryptoKit
import Foundation
import XCTest
@testable import PerryBrain

final class AcpRegistryTests: XCTestCase {
    private let registry = Data(#"""
    {"agents":[
      {"id":"pkg","name":"Pkg","version":"1.0","description":"d","distribution":{"npx":{"package":"pkg@1.0","args":["--acp"],"env":{"A":"1"}}}},
      {"id":"bin","name":"Bin","version":"2.0","distribution":{"binary":{"darwin-aarch64":{"archive":"https://example.invalid/bin.tar.gz","cmd":"./bin","args":["acp"],"sha256":"abc"}}}},
      {"id":"nosum","name":"NoSum","version":"1","distribution":{"binary":{"darwin-aarch64":{"archive":"https://example.invalid/x.tar.gz","cmd":"./x"}}}},
      {"id":"linux","name":"Linux","version":"1","distribution":{"binary":{"linux-x86_64":{"archive":"https://example.invalid/l.tar.gz","cmd":"./l"}}}},
      {"id":"plain","name":"Plain","version":"1","distribution":{"binary":{"darwin-aarch64":{"archive":"http://example.invalid/p.tar.gz","cmd":"./p","sha256":"abc"}}}}
    ]}
    """#.utf8)

    func testParsesOnlyAgentsThisMacCanRunOverHTTPS() {
        XCTAssertEqual(AcpRegistry.parse(registry).map(\.id), ["pkg", "bin", "nosum"])
    }

    func testPackageAgentsNeedTheirLauncherAndBinariesNeedAChecksum() throws {
        let entries = AcpRegistry.parse(registry)
        let npx = URL(fileURLWithPath: "/opt/homebrew/bin/npx")
        guard case .ready(let agent) = entries[0].availability(launcher: { $0 == "npx" ? npx : nil }) else {
            return XCTFail("expected a runnable agent")
        }
        XCTAssertEqual(agent.command, npx.path)
        XCTAssertEqual(agent.arguments, ["-y", "pkg@1.0", "--acp"])
        XCTAssertEqual(agent.environment, ["A": "1"])
        XCTAssertEqual(entries[0].availability(launcher: { _ in nil }), .unavailable("Needs Node.js (npx)."))
        guard case .download(_, "abc", "./bin", ["acp"], _) = entries[1].availability(launcher: { _ in nil }) else {
            return XCTFail("expected a verified download")
        }
        XCTAssertEqual(entries[2].availability(launcher: { _ in nil }), .unavailable("The registry gives no checksum, so Perry won’t download it."))
    }

    func testInstallVerifiesTheChecksumAndKeepsTheCommandInsideItsFolder() async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("acp-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work.appendingPathComponent("src"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: work) }
        let program = work.appendingPathComponent("src/agent")
        try "#!/bin/sh\n".write(to: program, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        let archive = work.appendingPathComponent("agent.tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", archive.path, "-C", work.appendingPathComponent("src").path, "agent"]
        try tar.run()
        tar.waitUntilExit()
        let bytes = try Data(contentsOf: archive)
        let sum = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        StubArchive.body = bytes
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubArchive.self]
        let session = URLSession(configuration: configuration)
        let entry = AcpRegistryEntry(id: "stub", name: "Stub", version: "1", summary: "", distributions: [])
        let remote = URL(string: "https://example.invalid/agent.tar.gz")!
        let root = work.appendingPathComponent("agents")

        let agent = try await AcpRegistry.install(entry, archive: remote, sha256: sum, command: "./agent", arguments: ["acp"], environment: [:], into: root, session: session)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: agent.command))
        XCTAssertEqual(agent.arguments, ["acp"])

        do {
            _ = try await AcpRegistry.install(entry, archive: remote, sha256: String(repeating: "0", count: 64), command: "./agent", arguments: [], environment: [:], into: root, session: session)
            XCTFail("expected a checksum failure")
        } catch let error as AcpInstallError {
            XCTAssertEqual(error, .checksumMismatch)
        }
        do {
            _ = try await AcpRegistry.install(entry, archive: remote, sha256: sum, command: "../../escape", arguments: [], environment: [:], into: root, session: session)
            XCTFail("expected the command to stay inside its folder")
        } catch let error as AcpInstallError {
            XCTAssertEqual(error, .missingCommand)
        }
        for unsafe in ["../victim", "..", "a/b", ""] {
            let bad = AcpRegistryEntry(id: unsafe, name: "Bad", version: "1", summary: "", distributions: [])
            do {
                _ = try await AcpRegistry.install(bad, archive: remote, sha256: sum, command: "./agent", arguments: [], environment: [:], into: root, session: session)
                XCTFail("expected \(unsafe) to be refused")
            } catch let error as AcpInstallError {
                XCTAssertEqual(error, .unsafeName)
            }
        }
    }
}

private final class StubArchive: URLProtocol {
    nonisolated(unsafe) static var body = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class AcpRegistryLiveTests: XCTestCase {
    func testFetchesTheRealRegistryAndInstallsAChecksummedAgent() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PERRY_LIVE_ACP_REGISTRY"] == "1", "Set PERRY_LIVE_ACP_REGISTRY=1 to contact the ACP registry.")
        let entries = try await AcpRegistry.fetch()
        XCTAssertGreaterThan(entries.count, 30)
        let goose = try XCTUnwrap(entries.first { $0.id == "goose" })
        guard case .download(let archive, let sha256, let command, let arguments, let environment) = goose.availability(launcher: { _ in nil }) else {
            return XCTFail("expected a checksummed download")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("acp-live-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let agent = try await AcpRegistry.install(goose, archive: archive, sha256: sha256, command: command, arguments: arguments, environment: environment, into: root)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: agent.command))
        XCTAssertEqual(agent.arguments, ["acp"])
    }
}
