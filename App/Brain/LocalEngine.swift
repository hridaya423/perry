import Darwin
import Foundation

protocol LocalEngineProcess: AnyObject {
    var isRunning: Bool { get }
    func terminate()
}

extension Process: LocalEngineProcess {}

@MainActor
final class LocalEngine {
    enum Lane: Equatable, Sendable {
        case interactive
        case deep(useMTP: Bool)
    }

    struct Model: Equatable, Sendable {
        let weights: URL
        let projector: URL?
        var draft: URL? = nil
    }

    struct Endpoint: Equatable, Sendable {
        let baseURL: URL
        let apiKey: String
    }

    enum EngineError: Error, Equatable {
        case unhealthy
        case noFreePort
    }

    typealias Launch = (_ binary: URL, _ arguments: [String]) throws -> any LocalEngineProcess
    typealias Health = @Sendable (_ baseURL: URL) async -> Bool

    static let contextTokens = 32768

    private let binary: URL
    private let directory: URL
    private let launch: Launch
    private let health: Health
    private let healthBudget: Duration
    private let freePort: () -> Int?
    private var process: (any LocalEngineProcess)?
    private var idleExit: Task<Void, Never>?
    private var starting: Task<Endpoint, Error>?
    private(set) var endpoint: Endpoint?
    private(set) var lane: Lane?

    init(
        binary: URL,
        directory: URL,
        launch: @escaping Launch = LocalEngine.launchProcess,
        health: @escaping Health = LocalEngine.checkHealth,
        healthBudget: Duration = .seconds(90),
        freePort: @escaping () -> Int? = LocalEngine.findFreePort
    ) {
        self.binary = binary
        self.directory = directory
        self.launch = launch
        self.health = health
        self.healthBudget = healthBudget
        self.freePort = freePort
    }

    static func arguments(lane: Lane, model: Model, port: Int, keyFile: URL, sleepIdleSeconds: Int?) -> [String] {
        var arguments = ["--model", model.weights.path]
        if let projector = model.projector { arguments += ["--mmproj", projector.path] }
        arguments += [
            "--host", "127.0.0.1", "--port", String(port), "--api-key-file", keyFile.path,
            "-ngl", "all", "-fa", "on", "-c", String(contextTokens), "-np", "1",
            "--image-max-tokens", "2048",
            "--cache-ram", "2048", "--ctx-checkpoints", "8", "--checkpoint-min-step", "1024",
        ]
        if let sleepIdleSeconds { arguments += ["--sleep-idle-seconds", String(sleepIdleSeconds)] }
        switch lane {
        case .interactive:
            arguments += [
                "--chat-template-kwargs", #"{"enable_thinking":false}"#,
                "--temp", "0.7", "--top-p", "0.8", "--top-k", "20", "--min-p", "0",
            ]
        case .deep(let useMTP):
            arguments += [
                "--reasoning-effort", "medium", "--reasoning-budget", "4096",
                "--reasoning-budget-message", "I must answer now.", "--reasoning-preserve",
                "--temp", "1.0", "--top-p", "0.95", "--top-k", "20", "--min-p", "0",
            ]
            if useMTP, let draft = model.draft {
                arguments += ["--model-draft", draft.path, "--spec-type", "draft-mtp", "--spec-draft-n-max", "2"]
            }
        }
        return arguments
    }

    func start(lane: Lane, model: Model, sleepIdleSeconds: Int?, exitAfterIdle: Duration?) async throws -> Endpoint {
        if let endpoint, self.lane == lane, process?.isRunning == true {
            noteUse(exitAfterIdle: exitAfterIdle)
            return endpoint
        }
        if let starting { return try await starting.value }
        let task = Task { try await boot(lane: lane, model: model, sleepIdleSeconds: sleepIdleSeconds, exitAfterIdle: exitAfterIdle) }
        starting = task
        defer { starting = nil }
        return try await task.value
    }

    private func boot(lane: Lane, model: Model, sleepIdleSeconds: Int?, exitAfterIdle: Duration?) async throws -> Endpoint {
        stop()
        guard let port = freePort() else { throw EngineError.noFreePort }
        let key = Self.randomKey()
        let keyFile = directory.appendingPathComponent("api-key")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: keyFile)
        guard FileManager.default.createFile(atPath: keyFile.path, contents: Data(key.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let process = try launch(binary, Self.arguments(lane: lane, model: model, port: port, keyFile: keyFile, sleepIdleSeconds: sleepIdleSeconds))
        self.process = process
        let baseURL = URL(string: "http://127.0.0.1:\(port)")!
        let deadline = ContinuousClock.now + healthBudget
        while ContinuousClock.now < deadline, process.isRunning {
            if await health(baseURL) {
                let endpoint = Endpoint(baseURL: baseURL.appendingPathComponent("v1"), apiKey: key)
                self.endpoint = endpoint
                self.lane = lane
                noteUse(exitAfterIdle: exitAfterIdle)
                return endpoint
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        stop()
        throw EngineError.unhealthy
    }

    func noteUse(exitAfterIdle: Duration?) {
        idleExit?.cancel()
        guard let exitAfterIdle else { return }
        idleExit = Task { [weak self] in
            try? await Task.sleep(for: exitAfterIdle)
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    func memoryPressure() {
        stop()
    }

    func stop() {
        idleExit?.cancel()
        idleExit = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        endpoint = nil
        lane = nil
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("api-key"))
    }

    private static func randomKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func launchProcess(binary: URL, arguments: [String]) throws -> any LocalEngineProcess {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    static let checkHealth: Health = { baseURL in
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 1
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    static func findFreePort() -> Int? {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return nil }
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, length) == 0 && getsockname(socket, $0, &length) == 0
            }
        }
        return bound ? Int(UInt16(bigEndian: address.sin_port)) : nil
    }
}
