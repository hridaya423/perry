import AppKit
import Foundation
import PerryBrain
import PerryCore

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
        case oauth
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
    private let http: any MCPHTTPPerforming
    private let authorizer: MCPAuthorizer
    private var live: [UUID: MCPConnector] = [:]
    private var challenges: [UUID: MCPAuthChallenge] = [:]

    static let browserUserAgent = LoopbackMCPAuthorizationUserAgent(open: { url in
        await MainActor.run { NSWorkspace.shared.open(url) }
    })

    init(
        directory: URL?,
        host: PerryToolHost,
        timeout: Duration = .seconds(20),
        keychain: KeychainStore = KeychainStore(service: CustomConnectors.keychainService),
        http: any MCPHTTPPerforming = URLSessionMCPHTTP(),
        userAgent: any MCPAuthorizationUserAgent = CustomConnectors.browserUserAgent
    ) {
        file = directory?.appendingPathComponent("connectors.json")
        self.host = host
        self.timeout = timeout
        self.keychain = keychain
        self.http = http
        authorizer = MCPAuthorizer(userAgent: userAgent, performer: http)
        if let file, let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([CustomConnector].self, from: data) {
            connectors = saved
        }
    }

    func connectAll() {
        for connector in connectors {
            reconnect(connector.id, signingIn: false)
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
                return .failed("I couldn’t save the key to your Keychain.")
            }
        } else {
            connector.secret = nil
        }
        connectors.append(connector)
        let result = await establish(connector, signingIn: true)
        if case .ready = result {
            save()
        } else {
            connectors.removeAll { $0.id == connector.id }
            status[connector.id] = nil
            try? keychain.deleteChecked(account: connector.id.uuidString)
        }
        return result
    }

    func reconnect(_ id: UUID, signingIn: Bool = true) {
        guard live[id] == nil, status[id] != .connecting, let connector = connectors.first(where: { $0.id == id }) else { return }
        status[id] = .connecting
        Task { await establish(connector, signingIn: signingIn) }
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
    private func establish(_ connector: CustomConnector, signingIn: Bool) async -> Status {
        let result = await connect(connector)
        guard let challenge = challenges.removeValue(forKey: connector.id), signingIn,
              case .url(let url) = connector.endpoint else { return result }
        status[connector.id] = .connecting
        let credential: MCPOAuthCredential
        do {
            credential = try await authorizer.signIn(resource: url, challenge: challenge)
        } catch {
            return fail(connector.id, error.localizedDescription)
        }
        guard let index = connectors.firstIndex(where: { $0.id == connector.id }) else { return .failed("Removed while connecting.") }
        do {
            try keychain.save(try Self.encode(credential), account: connector.id.uuidString)
        } catch {
            return fail(connector.id, "I couldn’t save the sign-in to your Keychain.")
        }
        connectors[index].secret = .oauth
        return await connect(connectors[index])
    }

    private func fail(_ id: UUID, _ message: String) -> Status {
        if connectors.contains(where: { $0.id == id }) {
            status[id] = .failed(message)
        }
        return .failed(message)
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
            if let unauthorized = error as? MCPUnauthorized, connector.secret != .bearer {
                challenges[connector.id] = unauthorized.challenge
            }
            result = ContinuousClock.now - started >= timeout
                ? .failed("The server didn’t answer within \(timeout.formatted(.units(allowed: [.seconds], width: .wide))).")
                : .failed(error is MCPUnauthorized && connector.secret == .bearer ? "The server didn’t accept your key." : error.localizedDescription)
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
            return try HTTPMCPTransport(endpoint: url, headers: ["Authorization": "Bearer \(value)"], performer: http)
        case (.url(let url), .oauth, let value?):
            guard let credential = try? JSONDecoder().decode(MCPOAuthCredential.self, from: Data(value.utf8)) else {
                return try HTTPMCPTransport(endpoint: url, performer: http)
            }
            let keychain = keychain
            let account = id.uuidString
            let session = MCPOAuthSession(credential: credential, performer: http, persist: { try? keychain.save(try Self.encode($0), account: account) })
            return try HTTPMCPTransport(endpoint: url, auth: session, performer: http)
        case (.url(let url), _, _):
            return try HTTPMCPTransport(endpoint: url, performer: http)
        }
    }

    private nonisolated static func encode(_ credential: MCPOAuthCredential) throws -> String {
        String(decoding: try JSONEncoder().encode(credential), as: UTF8.self)
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
