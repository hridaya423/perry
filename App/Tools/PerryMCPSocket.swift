import Foundation
import PerryBrain

/// Hosts the per-launch Unix socket that `perry-mcp` connects to. First line
/// from a client must be `{"token": "…"}` matching the 0600 token file;
/// anything else closes the connection. Subsequent lines go through
/// `MCPServer` and dispatch to `PerryToolHost` on the agent surface.
/// Background accept/serve threads touch only `host` (Sendable) and `directory`.
final class PerryMCPSocket: @unchecked Sendable {
    private let host: PerryToolHost
    private let directory: URL
    private var listenerFD: Int32 = -1
    private var acceptThread: Thread?

    init(host: PerryToolHost, directory: URL) {
        self.host = host
        self.directory = directory
    }

    private var socketPath: String {
        directory.appendingPathComponent("perry-mcp.sock").path
    }

    func start() throws {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
        listenerFD = fd

        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "perry-mcp-accept"
        thread.start()
        acceptThread = thread
    }

    func stop() {
        if listenerFD >= 0 { close(listenerFD); listenerFD = -1 }
        unlink(socketPath)
    }

    private func acceptLoop() {
        while true {
            let client = accept(listenerFD, nil, nil)
            if client < 0 { return }
            Thread { [weak self] in self?.serve(client: client) }.start()
        }
    }

    /// Raw POSIX IO only — FileHandle on a bare socket can raise Obj-C
    /// exceptions that try? cannot catch, and this runs on a plain Thread.
    private func serve(client fd: Int32) {
        defer { close(fd) }
        autoreleasepool {
            var pending = Data()

            func nextLine() -> String? {
                while true {
                    if let nl = pending.firstIndex(of: 0x0a) {
                        let line = pending.prefix(upTo: nl)
                        pending.removeSubrange(...nl)
                        return String(data: line, encoding: .utf8)
                    }
                    var buffer = [UInt8](repeating: 0, count: 8192)
                    let n = recv(fd, &buffer, buffer.count, 0)
                    guard n > 0 else { return nil }
                    pending.append(contentsOf: buffer[0..<n])
                }
            }
            func write(_ line: String) {
                let bytes = Array((line + "\n").utf8)
                _ = bytes.withUnsafeBufferPointer { send(fd, $0.baseAddress, $0.count, 0) }
            }

            // Auth first line: {"token": "…"}
            guard let hello = nextLine(),
                  let token = (try? JSONValue(parsing: Data(hello.utf8)))?["token"]?.stringValue,
                  SocketAuth.authorize(token, in: directory) else { return }

            let server = MCPServer(
                bridge: AppMCPBridge(
                    host: host,
                    approve: { call, spec in await ToolApprovalPresenter.present(call: call, spec: spec) }
                ),
                version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
            )
            while let line = nextLine() {
                let semaphore = DispatchSemaphore(value: 0)
                var responseLine: String?
                Task {
                    responseLine = await server.handle(line)
                    semaphore.signal()
                }
                semaphore.wait()
                if let responseLine { write(responseLine) }
            }
        }
    }
}

/// Bridges MCP calls into the app's tool host on the agent surface.
struct AppMCPBridge: MCPBridge {
    let host: PerryToolHost
    /// Approval hook injected by AgentCoordinator (intent cards). nil →
    /// orange/red calls fail closed.
    var approve: (@Sendable (ToolCall, ToolSpec) async -> ToolApproval)?

    func tools() async throws -> [ToolSpec] {
        host.specs(for: .agent)
    }

    func call(name: String, arguments: JSONValue) async throws -> ToolResult {
        await host.handle(
            ToolCall(id: UUID().uuidString, name: name, arguments: arguments),
            context: ToolContext(surface: .agent, approve: approve)
        )
    }
}
