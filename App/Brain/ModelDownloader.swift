import CryptoKit
import Foundation

struct ModelFile: Equatable, Sendable {
    let repo: String
    let path: String
    let revision: String
    let size: Int64
    let sha256: String

    var url: URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(path)")!
    }
}

struct ModelDownloader: Sendable {
    enum DownloadError: Error, Equatable {
        case notEnoughSpace(needed: Int64, available: Int64)
        case notInRepository(String)
        case checksumMismatch(String)
        case http(Int)
    }

    static let headroom: Int64 = 2 << 30

    var session: URLSession = .shared
    var freeSpace: @Sendable (URL) -> Int64? = ModelDownloader.availableCapacity

    func files(repo: String, revision: String, paths: [String]) async throws -> [ModelFile] {
        let url = URL(string: "https://huggingface.co/api/models/\(repo)/tree/\(revision)?recursive=true")!
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw DownloadError.http(status) }
        let entries = try JSONDecoder().decode([TreeEntry].self, from: data)
        return try paths.map { path in
            guard let entry = entries.first(where: { $0.path == path }), let lfs = entry.lfs else {
                throw DownloadError.notInRepository(path)
            }
            return ModelFile(repo: repo, path: path, revision: revision, size: lfs.size, sha256: lfs.oid)
        }
    }

    func download(
        _ files: [ModelFile],
        to directory: URL,
        progress: @escaping @Sendable (_ received: Int64, _ total: Int64) -> Void = { _, _ in }
    ) async throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pending = files.filter { !isComplete($0, in: directory) }
        let needed = pending.reduce(Int64(0)) { $0 + $1.size - partSize($1, in: directory) }
        if needed > 0, let available = freeSpace(directory), available < needed + Self.headroom {
            throw DownloadError.notEnoughSpace(needed: needed + Self.headroom, available: available)
        }
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        var finished = files.filter { isComplete($0, in: directory) }.reduce(Int64(0)) { $0 + $1.size }
        progress(finished, total)
        for file in pending {
            let base = finished
            try await fetch(file, in: directory) { progress(base + $0, total) }
            finished += file.size
        }
        return files.map { destination($0, in: directory) }
    }

    private func fetch(_ file: ModelFile, in directory: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let part = destination(file, in: directory).appendingPathExtension("part")
        if !FileManager.default.fileExists(atPath: part.path) {
            FileManager.default.createFile(atPath: part.path, contents: nil)
        }
        let handle = try FileHandle(forUpdating: part)
        defer { try? handle.close() }
        var hasher = SHA256()
        var offset: Int64 = 0
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            offset += Int64(chunk.count)
        }
        if offset < file.size {
            var request = URLRequest(url: file.url)
            if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
            let writer = PartWriter(handle: handle, hasher: hasher, offset: offset, progress: progress)
            hasher = try await writer.run(request, session: session)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == file.sha256.lowercased() else {
            try? FileManager.default.removeItem(at: part)
            throw DownloadError.checksumMismatch(file.path)
        }
        try FileManager.default.moveItem(at: part, to: destination(file, in: directory))
    }

    private func destination(_ file: ModelFile, in directory: URL) -> URL {
        directory.appendingPathComponent((file.path as NSString).lastPathComponent)
    }

    private func isComplete(_ file: ModelFile, in directory: URL) -> Bool {
        size(of: destination(file, in: directory)) == file.size
    }

    private func partSize(_ file: ModelFile, in directory: URL) -> Int64 {
        size(of: destination(file, in: directory).appendingPathExtension("part"))
    }

    private func size(of url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static let availableCapacity: @Sendable (URL) -> Int64? = { url in
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    private struct TreeEntry: Decodable {
        struct LFS: Decodable {
            let oid: String
            let size: Int64
        }
        let path: String
        let lfs: LFS?
    }
}

private final class PartWriter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let handle: FileHandle
    private var hasher: SHA256
    private var received: Int64
    private let progress: @Sendable (Int64) -> Void
    private var continuation: CheckedContinuation<SHA256, Error>?
    private var failure: Error?

    init(handle: FileHandle, hasher: SHA256, offset: Int64, progress: @escaping @Sendable (Int64) -> Void) {
        self.handle = handle
        self.hasher = hasher
        self.received = offset
        self.progress = progress
    }

    func run(_ request: URLRequest, session: URLSession) async throws -> SHA256 {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let task = session.dataTask(with: request)
                task.delegate = self
                task.resume()
            }
        } onCancel: {
            session.getAllTasks { tasks in
                tasks.filter { $0.delegate === self }.forEach { $0.cancel() }
            }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 206:
            return .allow
        case 200:
            do {
                try handle.truncate(atOffset: 0)
                hasher = SHA256()
                received = 0
                return .allow
            } catch {
                failure = error
                return .cancel
            }
        default:
            failure = ModelDownloader.DownloadError.http(status)
            return .cancel
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle.write(contentsOf: data)
        } catch {
            failure = error
            dataTask.cancel()
            return
        }
        hasher.update(data: data)
        received += Int64(data.count)
        progress(received)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = failure ?? error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume(returning: hasher)
        }
        continuation = nil
    }
}
