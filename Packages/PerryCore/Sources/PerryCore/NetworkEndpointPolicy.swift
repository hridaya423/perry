import Foundation

public enum NetworkEndpointError: Error, Equatable, LocalizedError, CustomStringConvertible {
    case missingScheme
    case missingHost
    case insecureRemoteEndpoint
    case unsupportedScheme(String)

    public var description: String {
        switch self {
        case .missingScheme:
            return "network endpoint is missing a scheme"
        case .missingHost:
            return "network endpoint is missing a host"
        case .insecureRemoteEndpoint:
            return "plaintext network endpoints are allowed only on loopback"
        case .unsupportedScheme(let scheme):
            return "unsupported network endpoint scheme: \(scheme)"
        }
    }

    public var errorDescription: String? { description }
}

public enum NetworkEndpointPolicy {
    public static func requireSafe(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else {
            throw NetworkEndpointError.missingScheme
        }
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            throw NetworkEndpointError.missingHost
        }
        switch scheme {
        case "https", "wss":
            return
        case "http", "ws":
            guard isLoopback(host) else {
                throw NetworkEndpointError.insecureRemoteEndpoint
            }
        default:
            throw NetworkEndpointError.unsupportedScheme(scheme)
        }
    }

    private static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "::1" || host.hasPrefix("127.")
    }
}
