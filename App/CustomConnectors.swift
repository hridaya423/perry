import Foundation
import PerryBrain
import PerryCore
import PerryGuide

struct CustomConnector: Codable, Identifiable, Hashable {
    enum Endpoint: Codable, Hashable {
        case command(String)
        case url(URL)
    }

    var id = UUID()
    var name: String
    var endpoint: Endpoint
    var secret: Secret?

    enum Secret: Codable, Hashable {
        case environment(String)
        case bearer
    }

    var summary: String {
        switch endpoint {
        case .command(let line): line
        case .url(let url): url.absoluteString
        }
    }
}

@MainActor
final class CustomConnectors: ObservableObject {
    enum Status: Equatable {
        case connecting
        case ready(toolCount: Int)
        case failed(String)
    }

    @Published private(set) var connectors: [CustomConnector] = []
    @Published private(set) var status: [UUID: Status] = [:]

    static let keychainService = "dev.perry.connectors"

    private let file: URL?
    private let host: PerryToolHost
    private let timeout: Duration
    private let keychain: KeychainStore
    private var live: [UUID: MCPConnector] = [:]

    init(directory: URL?, host: PerryToolHost, timeout: Duration = .seconds(20), keychain: KeychainStore = KeychainStore(service: CustomConnectors.keychainService)) {
        file = directory?.appendingPathComponent("connectors.json")
        self.host = host
        self.timeout = timeout
        self.keychain = keychain
        if let file, let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([CustomConnector].self, from: data) {
            connectors = saved
        }
    }

    func connectAll() {
        for connector in connectors {
            reconnect(connector.id)
        }
    }

    func add(_ connector: CustomConnector, secret value: String? = nil) async -> Status {
        let name = connector.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failed("Give the connector a name.") }
        if let existing = connectors.first(where: { MCPConnector.sanitize($0.name) == MCPConnector.sanitize(name) }) {
            return .failed(existing.name.caseInsensitiveCompare(name) == .orderedSame
                ? "A connector called \(name) already exists."
                : "That name is too close to \(existing.name). Pick another.")
        }
        if case .url(let url) = connector.endpoint, (try? NetworkEndpointPolicy.requireSafe(url)) == nil {
            return .failed("Use an https address. Plain http only works for servers on this Mac.")
        }
        var connector = connector
        connector.name = name
        if let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            switch connector.endpoint {
            case .command:
                guard case .environment(let variable) = connector.secret,
                      variable.wholeMatch(of: /[A-Za-z_][A-Za-z0-9_]*/) != nil else {
                    return .failed("Name the variable the server reads its key from, like API_KEY.")
                }
            case .url:
                connector.secret = .bearer
            }
            do {
                try keychain.save(value, account: connector.id.uuidString)
            } catch {
                return .failed("Perry couldn’t save the key to your keychain.")
            }
        } else {
            connector.secret = nil
        }
        connectors.append(connector)
        let result = await connect(connector)
        if case .ready = result {
            save()
        } else {
            connectors.removeAll { $0.id == connector.id }
            status[connector.id] = nil
            try? keychain.deleteChecked(account: connector.id.uuidString)
        }
        return result
    }

    func reconnect(_ id: UUID) {
        guard live[id] == nil, status[id] != .connecting, let connector = connectors.first(where: { $0.id == id }) else { return }
        status[id] = .connecting
        Task { await connect(connector) }
    }

    func remove(_ id: UUID) {
        connectors.removeAll { $0.id == id }
        status[id] = nil
        disconnect(id)
        try? keychain.deleteChecked(account: id.uuidString)
        save()
    }

    func disconnectAll() {
        for id in Array(live.keys) { disconnect(id) }
        status = [:]
    }

    func forgetAll() {
        disconnectAll()
        connectors = []
    }

    @discardableResult
    private func connect(_ connector: CustomConnector) async -> Status {
        status[connector.id] = .connecting
        let result: Status
        let started = ContinuousClock.now
        do {
            let client = try MCPConnector(transport: transport(for: connector), clientVersion: Self.version)
            let limit = timeout
            let work = Task {
                try await client.initialize()
                return try await client.makeExecutors(prefix: connector.name)
            }
            let watchdog = Task {
                try await Task.sleep(for: limit)
                work.cancel()
                await client.close()
            }
            defer { watchdog.cancel() }
            do {
                let executors = try await work.value
                guard connectors.contains(where: { $0.id == connector.id }) else {
                    await client.close()
                    return .failed("Removed while connecting.")
                }
                live[connector.id] = client
                host.setExecutors(executors, group: connector.id.uuidString)
                result = .ready(toolCount: executors.count)
            } catch {
                await client.close()
                throw error
            }
        } catch {
            result = ContinuousClock.now - started >= timeout
                ? .failed("The server didn’t answer within \(timeout.formatted(.units(allowed: [.seconds], width: .wide))).")
                : .failed(error.localizedDescription)
        }
        if connectors.contains(where: { $0.id == connector.id }) {
            status[connector.id] = result
        }
        return result
    }

    private func disconnect(_ id: UUID) {
        host.setExecutors([], group: id.uuidString)
        if let client = live.removeValue(forKey: id) {
            Task { await client.close() }
        }
    }

    private func transport(for connector: CustomConnector) throws -> any MCPTransport {
        let value = try connector.secret.flatMap { _ in try keychain.readChecked(account: connector.id.uuidString) }
        let id = connector.id
        let onExit: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.serverExited(id) }
        }
        switch (connector.endpoint, connector.secret, value) {
        case (.command(let line), .environment(let variable), let value?):
            return try StdioMCPTransport(command: "/bin/zsh", arguments: ["-lc", line], environment: [variable: value], onExit: onExit)
        case (.command(let line), _, _):
            return try StdioMCPTransport(command: "/bin/zsh", arguments: ["-lc", line], onExit: onExit)
        case (.url(let url), .bearer, let value?):
            return try HTTPMCPTransport(endpoint: url, headers: ["Authorization": "Bearer \(value)"])
        case (.url(let url), _, _):
            return try HTTPMCPTransport(endpoint: url)
        }
    }

    private func serverExited(_ id: UUID) {
        guard live.removeValue(forKey: id) != nil else { return }
        host.setExecutors([], group: id.uuidString)
        status[id] = .failed("The server stopped.")
    }

    private func save() {
        guard let file else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(connectors).write(to: file, options: .atomic)
    }

    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
}
