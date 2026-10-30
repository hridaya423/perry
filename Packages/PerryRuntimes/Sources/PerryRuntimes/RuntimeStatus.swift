import Foundation

public enum RuntimeInstallationSource: String, Codable, CaseIterable, Equatable, Sendable {
    case bundled
    case officialCLI
    case local
}

public struct RuntimeInstallationIdentity: Equatable, Sendable {
    public let source: RuntimeInstallationSource
    public let version: String?
    public let executablePath: String?
    public let artifactSHA256: String?

    public init(
        source: RuntimeInstallationSource,
        version: String? = nil,
        executablePath: String? = nil,
        artifactSHA256: String? = nil
    ) {
        self.source = source
        self.version = version
        self.executablePath = executablePath
        self.artifactSHA256 = artifactSHA256
    }
}

public enum RuntimeInstallationStatus: Equatable, Sendable {
    case notApplicable(RuntimeInstallationSource)
    case verified(RuntimeInstallationIdentity)
    case unverified(reason: String)

    public var isUsable: Bool {
        switch self {
        case .notApplicable, .verified:
            return true
        case .unverified:
            return false
        }
    }

    public var explanation: String {
        switch self {
        case .notApplicable(let source):
            return "installation verification is not applicable to \(source.rawValue)"
        case .verified:
            return "installation identity is verified"
        case .unverified(let reason):
            return reason.isEmpty ? "installation identity is unverified" : "installation identity is unverified: \(reason)"
        }
    }
}

public enum RuntimeAuthenticationStatus: Equatable, Sendable {
    case notRequired
    case configured
    case authenticated
    case missing
    case invalid(reason: String)
    case unknown(reason: String)

    public var isUsable: Bool {
        switch self {
        case .notRequired, .configured, .authenticated:
            return true
        case .missing, .invalid, .unknown:
            return false
        }
    }

    public var explanation: String {
        switch self {
        case .notRequired:
            return "authentication is not required"
        case .configured:
            return "credential is configured but has not been verified by the provider"
        case .authenticated:
            return "authenticated"
        case .missing:
            return "authentication is missing"
        case .invalid(let reason):
            return reason.isEmpty ? "authentication is invalid" : "authentication is invalid: \(reason)"
        case .unknown(let reason):
            return reason.isEmpty ? "authentication status is unknown" : "authentication status is unknown: \(reason)"
        }
    }
}
