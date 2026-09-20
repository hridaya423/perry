import Foundation

public enum PersistenceError: Error, Equatable, Sendable, LocalizedError, CustomStringConvertible {
    case recoveredCorruptFile(path: String, quarantinePath: String, reason: String)
    case quarantineFailed(path: String, reason: String)
    case readFailed(path: String, reason: String)
    case createDirectoryFailed(path: String, reason: String)
    case encodeFailed(path: String, reason: String)
    case writeFailed(path: String, reason: String)
    case removeFailed(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .recoveredCorruptFile(let path, let quarantinePath, let reason):
            return "Recovered corrupt persistence file \(path) as \(quarantinePath): \(reason)"
        case .quarantineFailed(let path, let reason):
            return "Could not quarantine persistence file \(path): \(reason)"
        case .readFailed(let path, let reason):
            return "Could not read persistence file \(path): \(reason)"
        case .createDirectoryFailed(let path, let reason):
            return "Could not create persistence directory \(path): \(reason)"
        case .encodeFailed(let path, let reason):
            return "Could not encode persistence file \(path): \(reason)"
        case .writeFailed(let path, let reason):
            return "Could not write persistence file \(path): \(reason)"
        case .removeFailed(let path, let reason):
            return "Could not remove persistence file \(path): \(reason)"
        }
    }

    public var description: String {
        errorDescription ?? "Persistence error"
    }
}
