import Foundation
import PerryBrain

final class PerryMCPSocket: @unchecked Sendable {
    private let host: PerryToolHost
    private let directory: URL
    private let toolConsent: ToolConsentStore
    private let workers: CuaWorkerService
    private let workerLease: ForegroundWorkerLease
    private let observations: AgentObservationStore
    private let lock = NSLock()
    private let ioCompletion = DispatchGroup()
    private var listenerFD: Int32 = -1
    private var listenerSource: DispatchSourceRead?
    private var stopping = false
    private var clients: [UUID: (fd: Int32, task: Task<Void, Never>)] = [:]

    init(
        host: PerryToolHost, directory: URL,
        workers: CuaWorkerService, workerLease: ForegroundWorkerLease,
        observations: AgentObservationStore = .shared
    ) {
        self.host = host
        self.directory = directory
        self.workers = workers
        self.workerLease = workerLease
        self.observations = observations
        self.toolConsent = ToolConsentStore(directory: directory)
    }

    private var socketPath: String {
        directory.appendingPathComponent("perry-mcp.sock").path
    }

    func start() throws {
        try lock.withLock {
            guard listenerFD < 0, !stopping else { throw POSIXError(.EALREADY) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            _ = try SocketAuth.ensureToken(in: directory)
            let path = socketPath
            unlink(path)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw POSIXError(.EIO) }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = Array(path.utf8CString)
            guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
                close(fd)
                throw POSIXError(.ENAMETOOLONG)
            }
            _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { dest in
                pathBytes.withUnsafeBufferPointer { src in memcpy(dest, src.baseAddress, src.count) }
            }
            let bound = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0, listen(fd, 8) == 0 else {
                close(fd)
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            // The socket inherits the umask — pin it to owner-only so the
            // token handshake can't be raced by another user on this machine.
            chmod(path, 0o600)
            guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
                close(fd)
                throw POSIXError(.EIO)
            }
            listenerFD = fd
            ioCompletion.enter()
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
            source.setEventHandler { [self] in
                while true {
                    let client = accept(fd, nil, nil)
                    if client < 0 { return }
                    guard fcntl(client, F_SETFL, 0) == 0 else { close(client); continue }
                    ioCompletion.enter()
                    Thread { [self] in
                        defer { ioCompletion.leave() }
                        serve(client: client)
                    }.start()
                }
            }
            source.setCancelHandler { [ioCompletion] in
                close(fd)
                ioCompletion.leave()
            }
            listenerSource = source
            source.resume()
        }
    }

    func closeAdmission() {
        lock.withLock {
            stopping = true
            listenerFD = -1
            listenerSource?.cancel()
            listenerSource = nil
            for client in clients.values {
                shutdown(client.fd, SHUT_RDWR)
                client.task.cancel()
            }
        }
    }

    func stop() async {
        closeAdmission()
        await withCheckedContinuation { continuation in
            ioCompletion.notify(queue: .global()) { continuation.resume() }
        }
        lock.withLock {
            unlink(socketPath)
            stopping = false
        }
    }

    private func serve(client fd: Int32) {
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        let id = UUID()
        let incoming = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingOldest(32))
        let completed = DispatchSemaphore(value: 0)
        let task: Task<Void, Never>? = lock.withLock {
            guard listenerFD >= 0, !stopping else { return nil }
            let task = Task { [self] in
                defer {
                    observations.remove(runID: id)
                    shutdown(fd, SHUT_RDWR)
                    completed.signal()
                }
                var iterator = incoming.stream.makeAsyncIterator()
                guard let hello = await iterator.next(),
                      let token = (try? JSONValue(parsing: Data(hello.utf8)))?["token"]?.stringValue,
                      SocketAuth.authorize(token, in: directory) else { return }
                let bridge = AppMCPBridge(runID: id, host: host, approve: { [toolConsent] call, spec in
                    await ToolApprovalPresenter.present(call: call, spec: spec, consentStore: toolConsent)
                })
                let server = MCPServer(bridge: bridge, version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
                do {
                    try await workerLease.withRun(id, workers: workers) {
                        for await line in incoming.stream {
                            try Task.checkCancellation()
                            if let response = await server.handle(line) {
                                try await Self.write(response, to: fd)
                            }
                        }
                    }
                } catch { return }
            }
            clients[id] = (fd, task)
            return task
        }
        guard let task else { close(fd); return }
        defer {
            incoming.continuation.finish()
            task.cancel()
            completed.wait()
            lock.withLock {
                clients[id] = nil
                close(fd)
            }
        }
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            pending.append(contentsOf: buffer[..<count])
            while let newline = pending.firstIndex(of: 0x0a) {
                guard pending.distance(from: pending.startIndex, to: newline) <= 1_048_576,
                      let line = String(data: pending.prefix(upTo: newline), encoding: .utf8) else { return }
                pending.removeSubrange(...newline)
                if case .dropped = incoming.continuation.yield(line) { return }
            }
            if pending.count > 1_048_576 { return }
        }
    }

    private static func write(_ line: String, to fd: Int32) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let bytes = Array((line + "\n").utf8)
                let error: POSIXError? = bytes.withUnsafeBytes { buffer in
                    var offset = 0
                    while offset < buffer.count {
                        let count = send(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
                        if count < 0, errno == EINTR { continue }
                        guard count > 0 else { return POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                        offset += count
                    }
                    return nil
                }
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}

struct AppMCPBridge: MCPBridge {
    let runID: UUID
    let host: PerryToolHost
    var approve: (@Sendable (ToolCall, ToolSpec) async -> ToolApproval)?

    init(runID: UUID = UUID(), host: PerryToolHost, approve: (@Sendable (ToolCall, ToolSpec) async -> ToolApproval)? = nil) {
        self.runID = runID
        self.host = host
        self.approve = approve
    }

    func tools() async throws -> [ToolSpec] {
        host.specs(for: .agent)
    }

    func call(name: String, arguments: JSONValue) async throws -> ToolResult {
        await host.handle(
            ToolCall(id: UUID().uuidString, name: name, arguments: arguments),
            context: ToolContext(surface: .agent, runID: runID, approve: approve)
        )
    }
}
