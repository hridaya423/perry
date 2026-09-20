import Foundation

public struct ActionID: Codable, Hashable, Sendable, RawRepresentable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        precondition(!rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "action ID must not be empty")
        self.rawValue = rawValue
    }

    public init(rawValue: String) {
        self.init(rawValue)
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    public var description: String {
        rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "action ID must not be empty")
        }
        self.rawValue = rawValue
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum ApprovalScope: Codable, Equatable, Hashable, Sendable, Comparable {
    case none
    case action
    case plan

    /// Strictness order: `.none` grants nothing, `.plan` authorizes the whole
    /// plan once, `.action` authorizes each action individually. A requirement
    /// satisfies a floor when it is at least as strict as the floor.
    private var strictnessRank: Int {
        switch self {
        case .none: return 0
        case .plan: return 1
        case .action: return 2
        }
    }

    public static func < (lhs: ApprovalScope, rhs: ApprovalScope) -> Bool {
        lhs.strictnessRank < rhs.strictnessRank
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        switch try container.decode(String.self) {
        case "none": self = .none
        case "action": self = .action
        case "plan": self = .plan
        default:
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unknown approval scope")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .none: try container.encode("none")
        case .action: try container.encode("action")
        case .plan: try container.encode("plan")
        }
    }
}

public enum IdempotencyPolicy: Codable, Equatable, Hashable, Sendable {
    case idempotent
    case nonIdempotent
    case keyed(String)

    public var canRepeat: Bool {
        switch self {
        case .idempotent, .keyed:
            return true
        case .nonIdempotent:
            return false
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value {
        case "idempotent": self = .idempotent
        case "nonIdempotent": self = .nonIdempotent
        case let keyed where keyed.hasPrefix("keyed:"):
            let key = String(keyed.dropFirst("keyed:".count))
            guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "idempotency key must not be empty")
            }
            self = .keyed(key)
        default:
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "unknown idempotency policy")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .idempotent: try container.encode("idempotent")
        case .nonIdempotent: try container.encode("nonIdempotent")
        case .keyed(let key): try container.encode("keyed:\(key)")
        }
    }
}
