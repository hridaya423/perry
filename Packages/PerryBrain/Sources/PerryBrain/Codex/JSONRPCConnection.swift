import Foundation

public struct JSONRPCError: Error, Equatable, Sendable, LocalizedError {
    public let code: Int
    public let message: String
    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
    public var errorDescription: String? { "JSON-RPC \(code): \(message)" }
}

public struct JSONRPCNotification: Sendable, Equatable {
    public let method: String
    public let params: JSONValue
}

public struct JSONRPCIncomingRequest: Sendable, Equatable {
    public let id: JSONValue
    public let method: String
    public let params: JSONValue
}

public enum JSONRPCEvent: Sendable, Equatable {
    case notification(JSONRPCNotification)
    case incomingRequest(JSONRPCIncomingRequest)
    case closed
}

public actor JSONRPCConnection {
    private let readHandle: FileHandle
    private let writeHandle: FileHandle
    private var nextID = 0
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var eventContinuations: [UUID: AsyncStream<JSONRPCEvent>.Continuation] = [:]
    private var isReading = false
    private var isClosed = false
    public var closed: Bool { isClosed }
    private let readBuffer = ReadBuffer()
    private var lineSink: AsyncStream<Data>.Continuation?

    private final class ReadBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var buffered = Data()

        func append(_ data: Data, onLine: (Data) -> Void) {
            lock.withLock {
                buffered.append(data)
                while let newline = buffered.firstIndex(of: 0x0A) {
                    let line = Data(buffered[..<newline])
                    buffered = Data(buffered[buffered.index(after: newline)...])
                    onLine(line)
                }
            }
        }
    }

    private let stampsVersion: Bool

    public init(readHandle: FileHandle, writeHandle: FileHandle, stampsVersion: Bool = false) {
        self.readHandle = readHandle
        self.writeHandle = writeHandle
        self.stampsVersion = stampsVersion
    }

    public var events: AsyncStream<JSONRPCEvent> {
        AsyncStream { continuation in
            guard !isClosed else { continuation.finish(); return }
            let key = UUID()
            eventContinuations[key] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(key) }
            }
        }
    }

    private func removeContinuation(_ key: UUID) {
        eventContinuations.removeValue(forKey: key)
    }

    private func broadcast(_ event: JSONRPCEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    /// Lines are funneled through one stream and handled by a single task so responses and
    /// notifications reach subscribers in wire order (per-line Tasks would reorder deltas).
    public func start() {
        guard !isReading else { return }
        isReading = true
        let (lines, lineSink) = AsyncStream<Data>.makeStream()
        self.lineSink = lineSink
        let buffer = readBuffer
        readHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                lineSink.finish()
                return
            }
            buffer.append(data) { lineSink.yield($0) }
        }
        Task { [weak self] in
            for await line in lines {
                await self?.dispatch(line: line)
            }
            await self?.finishClosed()
        }
    }

    private func dispatch(line: Data) {
        let trimmed = line.drop(while: { $0 == 0x0D || $0 == 0x20 })
        guard !trimmed.isEmpty,
              let value = try? JSONValue(parsing: Data(trimmed)),
              let object = value.objectValue else { return }
        let method = object["method"]?.stringValue
        let id = object["id"]
        if let method, let id {
            broadcast(.incomingRequest(JSONRPCIncomingRequest(id: id, method: method, params: object["params"] ?? .null)))
        } else if let method {
            broadcast(.notification(JSONRPCNotification(method: method, params: object["params"] ?? .null)))
        } else if let id {
            resolvePending(id: id, result: object["result"], error: object["error"])
        }
    }

    private func resolvePending(id: JSONValue, result: JSONValue?, error: JSONValue?) {
        let key = Self.idKey(id)
        guard let continuation = pending.removeValue(forKey: key) else { return }
        if let error {
            let code = Int(error["code"]?.doubleValue ?? -32000)
            let message = error["message"]?.stringValue ?? "request failed"
            continuation.resume(throwing: JSONRPCError(code: code, message: message))
        } else {
            continuation.resume(returning: result ?? .null)
        }
    }

    private static func idKey(_ id: JSONValue) -> String {
        switch id {
        case .string(let s): return "s:\(s)"
        case .number(let n):
            if n.rounded() == n, abs(n) < 9.0e15 {
                return "n:\(Int64(n))"
            }
            return "n:\(n)"
        default: return "x:\(id)"
        }
    }

    public func request(_ method: String, params: JSONValue = .object([:])) async throws -> JSONValue {
        if isClosed { throw JSONRPCError(code: -32098, message: "connection closed") }
        nextID += 1
        let id = nextID
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending["n:\(id)"] = continuation
                do {
                    try write(.object([
                        "id": .number(Double(id)),
                        "method": .string(method),
                        "params": params,
                    ]))
                } catch {
                    pending.removeValue(forKey: "n:\(id)")
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { await self.cancelPending("n:\(id)") }
        }
    }

    private func cancelPending(_ key: String) {
        pending.removeValue(forKey: key)?.resume(throwing: CancellationError())
    }

    public func notify(_ method: String, params: JSONValue = .object([:])) throws {
        try write(.object(["method": .string(method), "params": params]))
    }

    public func respond(to id: JSONValue, result: JSONValue) throws {
        try write(.object(["id": id, "result": result]))
    }

    public func respondError(to id: JSONValue, code: Int = -32000, message: String) throws {
        try write(.object([
            "id": id,
            "error": .object(["code": .number(Double(code)), "message": .string(message)]),
        ]))
    }

    private func write(_ message: JSONValue) throws {
        var message = message
        if stampsVersion, case .object(var fields) = message {
            fields["jsonrpc"] = .string("2.0")
            message = .object(fields)
        }
        var data = try message.data()
        data.append(0x0A)
        try writeHandle.write(contentsOf: data)
    }

    private func finishClosed() {
        guard !isClosed else { return }
        isClosed = true
        let stranded = pending
        pending.removeAll()
        for (_, continuation) in stranded {
            continuation.resume(throwing: JSONRPCError(code: -32098, message: "connection closed"))
        }
        broadcast(.closed)
        for continuation in eventContinuations.values {
            continuation.finish()
        }
        eventContinuations.removeAll()
    }

    public func close() {
        readHandle.readabilityHandler = nil
        lineSink?.finish()
        finishClosed()
    }
}
