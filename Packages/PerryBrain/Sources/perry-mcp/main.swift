import Foundation
import PerryBrain

// perry-mcp: a stdio proxy. MCP clients (Claude Code, OpenCode) speak
// newline-delimited JSON-RPC on stdin/stdout; this forwards each line to
// Perry's per-launch Unix socket after presenting the shared token, and
// writes socket responses back to stdout.
//
// Socket handshake: the client sends `{"token": "<file token>"}` as the first
// line; the app closes the connection unless it matches.

let supportDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Perry", isDirectory: true)
let socketPath = ProcessInfo.processInfo.environment["PERRY_MCP_SOCKET"]
    ?? supportDir.appendingPathComponent("perry-mcp.sock").path

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("perry-mcp: \(message)\n".utf8))
    exit(2)
}

let token = ProcessInfo.processInfo.environment["PERRY_MCP_TOKEN"]
    ?? (try? String(contentsOf: supportDir.appendingPathComponent(SocketAuth.tokenFileName),
                    encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
guard let token, !token.isEmpty else {
    fail("no auth token — Perry's MCP socket needs Perry running once to mint it")
}

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { fail("socket() failed: \(errno)") }

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let pathBytes = Array(socketPath.utf8CString)
guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
    fail("socket path too long")
}
_ = withUnsafeMutablePointer(to: &addr.sun_path.0) { dest in
    pathBytes.withUnsafeBufferPointer { src in
        memcpy(dest, src.baseAddress, src.count)
    }
}
let connected = withUnsafePointer(to: &addr) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard connected == 0 else { fail("connect failed — is Perry running? (\(errno))") }

// Raw POSIX IO — FileHandle on a socket can raise uncatchable NSExceptions.
func socketWrite(_ fd: Int32, _ string: String) {
    var bytes = Array(string.utf8)
    bytes.withUnsafeBufferPointer { ptr in
        var sent = 0
        while sent < bytes.count {
            let n = send(fd, ptr.baseAddress! + sent, bytes.count - sent, 0)
            if n <= 0 { return }
            sent += n
        }
    }
}

let debug = ProcessInfo.processInfo.environment["PERRY_MCP_DEBUG"] != nil
func trace(_ message: String) {
    if debug { FileHandle.standardError.write(Data("perry-mcp: \(message)\n".utf8)) }
}

// Hello: present the token.
socketWrite(fd, "{\"token\":\"\(token)\"}\n")
trace("sent hello, fd=\(fd)")

// Socket → stdout, one JSON-RPC line per write.
let pump = Thread {
    var pending = Data()
    var buffer = [UInt8](repeating: 0, count: 8192)
    while true {
        let n = recv(fd, &buffer, buffer.count, 0)
        if n <= 0 { break }
        pending.append(contentsOf: buffer[0..<n])
        if debug { FileHandle.standardError.write(Data("perry-mcp: ← \(n) bytes\n".utf8)) }
        while let nl = pending.firstIndex(of: 0x0a) {
            let line = pending.prefix(upTo: nl)
            pending.removeSubrange(...nl)
            fwrite(Array(line + [0x0a]), 1, line.count + 1, stdout)
        }
        fflush(stdout)
    }
    exit(0)
}
pump.start()

// stdin → socket.
while let line = readLine() {
    trace("→ \(line.prefix(120))")
    socketWrite(fd, line + "\n")
}
trace("stdin closed")
exit(0)
