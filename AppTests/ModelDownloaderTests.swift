import CryptoKit
import os
import XCTest
@testable import Perry

private final class StubServer: URLProtocol {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var honoursRange = true
    nonisolated(unsafe) static var tree = Data()
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let url = request.url!
        if url.path.hasPrefix("/api/models/") {
            respond(200, Self.tree)
            return
        }
        if Self.honoursRange, let range = request.value(forHTTPHeaderField: "Range"),
           let start = Int(range.dropFirst("bytes=".count).dropLast()) {
            respond(206, Self.body.subdata(in: start..<Self.body.count))
        } else {
            respond(200, Self.body)
        }
    }

    override func stopLoading() {}

    private func respond(_ status: Int, _ data: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data.prefix(data.count / 2))
        client?.urlProtocol(self, didLoad: data.dropFirst(data.count / 2))
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class ModelDownloaderTests: XCTestCase {
    private var directory: URL!
    private var downloader: ModelDownloader!
    private let body = Data((0..<10_000).map { UInt8($0 % 251) })

    private var file: ModelFile {
        ModelFile(repo: "unsloth/Qwen", path: "sub/model.gguf", revision: "main", size: Int64(body.count), sha256: Self.hex(body))
    }

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubServer.self]
        downloader = ModelDownloader(session: URLSession(configuration: configuration), freeSpace: { _ in 100 << 30 })
        StubServer.body = body
        StubServer.honoursRange = true
        StubServer.requests = []
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func testTheTreeListingSuppliesSizeAndChecksum() async throws {
        StubServer.tree = Data(#"[{"type":"file","path":"README.md","size":12},{"type":"file","path":"sub/model.gguf","size":10000,"lfs":{"oid":"abc","size":10000,"pointerSize":134}}]"#.utf8)
        let files = try await downloader.files(repo: "unsloth/Qwen", revision: "main", paths: ["sub/model.gguf"])
        XCTAssertEqual(files, [ModelFile(repo: "unsloth/Qwen", path: "sub/model.gguf", revision: "main", size: 10000, sha256: "abc")])
        XCTAssertEqual(StubServer.requests.first?.url?.absoluteString, "https://huggingface.co/api/models/unsloth/Qwen/tree/main?recursive=true")
        do {
            _ = try await downloader.files(repo: "unsloth/Qwen", revision: "main", paths: ["README.md"])
            XCTFail("A file without a checksum was accepted")
        } catch {
            XCTAssertEqual(error as? ModelDownloader.DownloadError, .notInRepository("README.md"))
        }
    }

    func testAFreshDownloadIsVerifiedAndReportsFullProgress() async throws {
        let seen = OSAllocatedUnfairLock<[Int64]>(initialState: [])
        let urls = try await downloader.download([file], to: directory) { received, _ in seen.withLock { $0.append(received) } }
        XCTAssertEqual(try Data(contentsOf: urls[0]), body)
        XCTAssertEqual(urls[0].lastPathComponent, "model.gguf")
        XCTAssertEqual(seen.withLock { $0.last }, Int64(body.count))
        XCTAssertNil(StubServer.requests.first?.value(forHTTPHeaderField: "Range"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: urls[0].appendingPathExtension("part").path))
    }

    func testAnInterruptedDownloadResumesFromThePartFile() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try body.prefix(4_000).write(to: directory.appendingPathComponent("model.gguf.part"))
        let urls = try await downloader.download([file], to: directory)
        XCTAssertEqual(StubServer.requests.first?.value(forHTTPHeaderField: "Range"), "bytes=4000-")
        XCTAssertEqual(try Data(contentsOf: urls[0]), body)
    }

    func testAServerThatIgnoresTheRangeRestartsTheFile() async throws {
        StubServer.honoursRange = false
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try body.prefix(4_000).write(to: directory.appendingPathComponent("model.gguf.part"))
        let urls = try await downloader.download([file], to: directory)
        XCTAssertEqual(try Data(contentsOf: urls[0]), body)
    }

    func testAChecksumMismatchRejectsTheFile() async {
        var corrupt = body
        corrupt[10] ^= 0xFF
        StubServer.body = corrupt
        do {
            _ = try await downloader.download([file], to: directory)
            XCTFail("A corrupt file was accepted")
        } catch {
            XCTAssertEqual(error as? ModelDownloader.DownloadError, .checksumMismatch("sub/model.gguf"))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testTooLittleFreeSpaceStopsBeforeAnyRequest() async {
        downloader.freeSpace = { _ in 1 << 30 }
        do {
            _ = try await downloader.download([file], to: directory)
            XCTFail("The download started without room")
        } catch {
            XCTAssertEqual(error as? ModelDownloader.DownloadError, .notEnoughSpace(needed: 10_000 + ModelDownloader.headroom, available: 1 << 30))
        }
        XCTAssertTrue(StubServer.requests.isEmpty)
    }

    func testACompleteFileIsNotFetchedAgain() async throws {
        _ = try await downloader.download([file], to: directory)
        StubServer.requests = []
        downloader.freeSpace = { _ in 0 }
        _ = try await downloader.download([file], to: directory)
        XCTAssertTrue(StubServer.requests.isEmpty)
    }
}

