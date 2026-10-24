import Foundation
import PerryBrain

final class MCPScopeRelay: MCPScopeHost, @unchecked Sendable {
    private let lock = NSLock()
    private weak var current: PerryMCPSocket?

    var socket: PerryMCPSocket? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    func openScope(_ bridge: any MCPBridge) throws -> MCPScope {
        guard let socket else { throw POSIXError(.ENOTCONN) }
        return try socket.openScope(bridge)
    }
}

/// Perry's MCP socket across the app's lifetime: a delayed start after
/// launch, closed admission while maintenance owns the app, a restart when
/// it hands control back, and a stop for quit or erase.
@MainActor
final class MCPSocketLifecycle {
    private let makeSocket: (URL) -> PerryMCPSocket
    private let mayStart: () -> Bool
    private let reportFailure: (String) -> Void
    private let scopes: MCPScopeRelay
    private var socket: PerryMCPSocket?
    private var startup: Task<Void, Never>?

    init(
        makeSocket: @escaping (URL) -> PerryMCPSocket,
        mayStart: @escaping () -> Bool,
        reportFailure: @escaping (String) -> Void,
        scopes: MCPScopeRelay = MCPScopeRelay()
    ) {
        self.scopes = scopes
        self.makeSocket = makeSocket
        self.mayStart = mayStart
        self.reportFailure = reportFailure
    }

    func startAfterLaunch(directory: URL) {
        startup = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
                guard let self, self.mayStart() else { return }
                defer { self.startup = nil }
                let socket = self.makeSocket(directory)
                try socket.start()
                self.socket = socket
                self.scopes.socket = socket
            } catch is CancellationError {
            } catch {
                self?.reportFailure("Perry could not start its tool connection: \(error.localizedDescription)")
            }
        }
    }

    /// Maintenance took the app: no pending start, no new connections.
    func suspend() {
        startup?.cancel()
        socket?.closeAdmission()
    }

    /// Maintenance handed the app back: restart a socket that was running.
    func resume() {
        guard let socket else { return }
        let previousStartup = startup
        startup = Task { @MainActor [weak self] in
            await previousStartup?.value
            await socket.stop()
            guard let self, !Task.isCancelled, self.mayStart() else { return }
            defer { self.startup = nil }
            do {
                try socket.start()
            } catch {
                self.reportFailure("Perry could not restart its tool connection: \(error.localizedDescription)")
            }
        }
    }

    /// Quit: stops the socket but keeps it, so a cancelled quit can resume it.
    func stop() async {
        await startup?.value
        await socket?.stop()
    }

    /// Erase: stops and forgets the socket; it comes back on the next launch.
    func discard() async {
        await startup?.value
        startup = nil
        await socket?.stop()
        socket = nil
        scopes.socket = nil
    }
}
