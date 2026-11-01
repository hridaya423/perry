import Foundation
import Network

public struct LoopbackMCPAuthorizationUserAgent: MCPAuthorizationUserAgent {
    private let open: @Sendable (URL) async -> Bool
    private let timeout: Duration

    public init(open: @escaping @Sendable (URL) async -> Bool, timeout: Duration = .seconds(300)) {
        self.open = open
        self.timeout = timeout
    }

    public func authorize(_ makeAuthorizationURL: @Sendable (URL) async throws -> URL) async throws -> URL {
        let receiver = try LoopbackReceiver()
        defer { receiver.stop() }
        let port = try await receiver.start()
        guard let redirectURI = URL(string: "http://127.0.0.1:\(port)/callback") else { throw MCPAuthError.browserUnavailable }
        let authorizationURL = try await makeAuthorizationURL(redirectURI)
        guard await open(authorizationURL) else { throw MCPAuthError.browserUnavailable }
        return try await receiver.callback(timeout: timeout)
    }
}

private final class LoopbackReceiver: @unchecked Sendable {
    private static let page = Data("<!doctype html><meta charset=utf-8><title>Perry</title><body style=\"font:16px -apple-system;margin:4em auto;max-width:28em\"><p>You can close this tab and return to Perry.</p>".utf8)

    private let listener: NWListener
    private let queue = DispatchQueue(label: "ai.perry.brain.mcp-loopback")
    private let ports: AsyncThrowingStream<UInt16, Error>
    private let portSink: AsyncThrowingStream<UInt16, Error>.Continuation
    private let callbacks: AsyncThrowingStream<URL, Error>
    private let callbackSink: AsyncThrowingStream<URL, Error>.Continuation

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        (ports, portSink) = AsyncThrowingStream.makeStream()
        (callbacks, callbackSink) = AsyncThrowingStream.makeStream()
    }

    func start() async throws -> UInt16 {
        listener.stateUpdateHandler = { [weak self, portSink, callbackSink] state in
            switch state {
            case .ready:
                if let port = self?.listener.port?.rawValue {
                    portSink.yield(port)
                    portSink.finish()
                }
            case .failed(let error):
                portSink.finish(throwing: error)
                callbackSink.finish(throwing: error)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: self?.queue ?? .global())
            self?.read(connection, buffered: Data())
        }
        listener.start(queue: queue)
        for try await port in ports { return port }
        throw MCPAuthError.browserUnavailable
    }

    func callback(timeout: Duration) async throws -> URL {
        try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask {
                for try await url in self.callbacks { return url }
                try Task.checkCancellation()
                throw MCPAuthError.timedOut
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw MCPAuthError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    func stop() {
        listener.cancel()
        portSink.finish()
        callbackSink.finish()
    }

    private func read(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            let buffer = buffered + (data ?? Data())
            if let end = buffer.range(of: Data("\r\n".utf8)) {
                self?.respond(to: connection, requestLine: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            } else if error == nil, !isComplete, buffer.count < 4096 {
                self?.read(connection, buffered: buffer)
            } else {
                connection.cancel()
            }
        }
    }

    private func respond(to connection: NWConnection, requestLine: String) {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET", let port = listener.port?.rawValue,
              let target = URL(string: "http://127.0.0.1:\(port)\(parts[1])"), target.path == "/callback" else {
            send(connection, status: "404 Not Found", body: Data())
            return
        }
        send(connection, status: "200 OK", body: Self.page)
        callbackSink.yield(target)
        callbackSink.finish()
    }

    private func send(_ connection: NWConnection, status: String, body: Data) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
    }
}
