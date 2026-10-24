import Foundation

public struct MCPScope: Sendable {
    public let socketPath: String
    public let token: String
    public let close: @Sendable () -> Void

    public init(socketPath: String, token: String, close: @escaping @Sendable () -> Void) {
        self.socketPath = socketPath
        self.token = token
        self.close = close
    }
}

public protocol MCPScopeHost: Sendable {
    func openScope(_ bridge: any MCPBridge) throws -> MCPScope
}
