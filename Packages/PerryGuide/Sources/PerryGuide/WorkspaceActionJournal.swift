import Foundation
import PerryCore
import PerryRuntimes

public enum WorkspaceActionJournal: Codable, Sendable {
    public struct Attempt: Codable, Sendable {
        public let id: UUID
        public let actionIndex: Int
        public let grant: ExecutionApprovalGrant

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case id, actionIndex, grant
        }

        init(actionIndex: Int, grant: ExecutionApprovalGrant) {
            id = UUID()
            self.actionIndex = actionIndex
            self.grant = grant
        }

        public init(from decoder: Decoder) throws {
            let fields = try WorkspaceJournalDecodingFields(
                decoder,
                allowed: Set(CodingKeys.allCases.map(\.rawValue))
            )
            id = try fields.decode(UUID.self, "id")
            actionIndex = try fields.decode(Int.self, "actionIndex")
            grant = try fields.decode(ExecutionApprovalGrant.self, "grant")
        }

    }

    case prepared(Attempt)
    case dispatched(Attempt)
    case verified(Attempt, WorkspaceFileExecutionReceipt)

    public var attempt: Attempt {
        switch self {
        case .prepared(let attempt), .dispatched(let attempt), .verified(let attempt, _): return attempt
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case prepared, dispatched, verified
    }

    private enum VerifiedCodingKeys: String, CodingKey, CaseIterable {
        case attempt = "_0"
        case receipt = "_1"
    }

    public init(from decoder: Decoder) throws {
        let fields = try WorkspaceJournalDecodingFields(
            decoder,
            allowed: Set(CodingKeys.allCases.map(\.rawValue))
        )
        guard fields.allKeys.count == 1, let name = fields.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "workspace journal requires exactly one phase"
            ))
        }

        switch name {
        case CodingKeys.prepared.rawValue, CodingKeys.dispatched.rawValue:
            let payload = try WorkspaceJournalDecodingFields(
                fields.decoder(name),
                allowed: Set(["_0"])
            )
            let attempt = try Attempt(from: payload.decoder("_0"))
            self = name == CodingKeys.prepared.rawValue ? .prepared(attempt) : .dispatched(attempt)
        case CodingKeys.verified.rawValue:
            let payload = try WorkspaceJournalDecodingFields(
                fields.decoder(name),
                allowed: Set(VerifiedCodingKeys.allCases.map(\.rawValue))
            )
            self = .verified(
                try Attempt(from: payload.decoder("_0")),
                try WorkspaceFileExecutionReceipt(from: payload.decoder("_1"))
            )
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "unknown workspace journal phase"
            ))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .prepared(let attempt):
            var payload = fields.nestedContainer(keyedBy: VerifiedCodingKeys.self, forKey: .prepared)
            try payload.encode(attempt, forKey: .attempt)
        case .dispatched(let attempt):
            var payload = fields.nestedContainer(keyedBy: VerifiedCodingKeys.self, forKey: .dispatched)
            try payload.encode(attempt, forKey: .attempt)
        case .verified(let attempt, let receipt):
            var payload = fields.nestedContainer(keyedBy: VerifiedCodingKeys.self, forKey: .verified)
            try payload.encode(attempt, forKey: .attempt)
            try payload.encode(receipt, forKey: .receipt)
        }
    }

    func validate(plan: PerryRuntimes.ExecutionPlan, checkpoint: TaskCheckpoint) throws {
        let attempt = attempt
        guard plan.actions.indices.contains(attempt.actionIndex),
              attempt.grant.taskID == plan.taskID, attempt.grant.planID == plan.planID,
              try attempt.grant.planDigest == plan.approvalDigest() else {
            throw ExecutionError(message: "workspace journal does not match its plan")
        }
        let action = plan.actions[attempt.actionIndex]
        guard case .action(let approvedID) = attempt.grant.scope, approvedID == action.id,
              action.approvalRequirement == .action,
              case .transform(_, let command) = action.operation else {
            throw ExecutionError(message: "workspace journal does not identify an approved file transform")
        }
        switch self {
        case .prepared:
            guard checkpoint.nextStepIndex == attempt.actionIndex, checkpoint.inFlightStepID == nil,
                  checkpoint.suspendedStepID == nil else {
                throw ExecutionError(message: "prepared workspace checkpoint is inconsistent")
            }
        case .dispatched:
            guard checkpoint.nextStepIndex == attempt.actionIndex,
                  checkpoint.inFlightStepID == action.id.rawValue, checkpoint.suspendedStepID == nil else {
                throw ExecutionError(message: "dispatched workspace checkpoint is inconsistent")
            }
        case .verified(_, let receipt):
            guard checkpoint.nextStepIndex == attempt.actionIndex + 1,
                  checkpoint.inFlightStepID == nil, checkpoint.suspendedStepID == nil,
                  receipt.planID == plan.planID, receipt.actionID == action.id,
                  receipt.planDigest == attempt.grant.planDigest else {
                throw ExecutionError(message: "verified workspace receipt is inconsistent")
            }
            switch command {
            case .createUTF8File(let path, let contents):
                switch receipt.effect {
                case .createdFile(let receiptPath, let byteCount), .legacy(let receiptPath, let byteCount):
                    guard Array(receiptPath.utf8) == Array(path.utf8),
                          byteCount == contents.utf8.count else {
                        throw ExecutionError(message: "verified workspace receipt is inconsistent")
                    }
                default:
                    throw ExecutionError(message: "verified workspace receipt is inconsistent")
                }
            case .createDirectory(let path):
                switch receipt.effect {
                case .createdDirectory(let receiptPath):
                    guard Array(receiptPath.utf8) == Array(path.utf8) else {
                        throw ExecutionError(message: "verified workspace receipt is inconsistent")
                    }
                case .legacy(let receiptPath, let byteCount):
                    guard Array(receiptPath.utf8) == Array(path.utf8), byteCount == 0 else {
                        throw ExecutionError(message: "verified workspace receipt is inconsistent")
                    }
                default:
                    throw ExecutionError(message: "verified workspace receipt is inconsistent")
                }
            case .rename(let source, let destination):
                switch receipt.effect {
                case .renamed(let receiptSource, let receiptDestination, let device, let inode):
                    guard case .renamedItem(let expectedDevice, let expectedInode) = action.postcondition,
                          Array(receiptSource.utf8) == Array(source.utf8),
                          Array(receiptDestination.utf8) == Array(destination.utf8),
                          device == expectedDevice, inode == expectedInode else {
                        throw ExecutionError(message: "verified workspace receipt is inconsistent")
                    }
                case .legacy(let receiptPath, let byteCount):
                    guard Array(receiptPath.utf8) == Array(destination.utf8), byteCount == 0 else {
                        throw ExecutionError(message: "verified workspace receipt is inconsistent")
                    }
                default:
                    throw ExecutionError(message: "verified workspace receipt is inconsistent")
                }
            case .moveToTrash(let path):
                switch receipt.effect {
                case .trashed(let source, _, let device, let inode):
                    guard case .trashedItem(let expectedDevice, let expectedInode) = action.postcondition,
                          Array(source.utf8) == Array(path.utf8),
                          device == expectedDevice, inode == expectedInode else {
                        throw ExecutionError(message: "verified workspace receipt is inconsistent")
                    }
                case .legacy(let receiptPath, let byteCount):
                    guard Array(receiptPath.utf8) == Array(path.utf8), byteCount == 0 else {
                        throw ExecutionError(message: "verified workspace receipt is inconsistent")
                    }
                default:
                    throw ExecutionError(message: "verified workspace receipt is inconsistent")
                }
            case .restoreFromTrash(let entryName, let destination):
                switch receipt.effect {
                case .restored(let source, let receiptEntry, let device, let inode):
                    guard case .renamedItem(let expectedDevice, let expectedInode) = action.postcondition,
                          Array(source.utf8) == Array(destination.utf8),
                          receiptEntry == entryName,
                          device == expectedDevice, inode == expectedInode else {
                        throw ExecutionError(message: "verified workspace receipt is inconsistent")
                    }
                default:
                    throw ExecutionError(message: "verified workspace receipt is inconsistent")
                }
            }
        }
    }
}

struct WorkspaceJournalDecodingFields {
    private let values: KeyedDecodingContainer<Key>

    init(_ decoder: Decoder, allowed: Set<String>) throws {
        values = try decoder.container(keyedBy: Key.self)
        let unknown = Set(values.allKeys.map(\.stringValue)).subtracting(allowed)
        guard unknown.isEmpty else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "unknown workspace journal fields: \(unknown.sorted().joined(separator: ", "))"
            ))
        }
    }

    var allKeys: [String] {
        values.allKeys.map(\.stringValue)
    }

    func decode<T: Decodable>(_ type: T.Type = T.self, _ key: String) throws -> T {
        try values.decode(type, forKey: Key(key))
    }

    func decoder(_ key: String) throws -> Decoder {
        try values.superDecoder(forKey: Key(key))
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init(_ value: String) {
            stringValue = value
        }

        init?(stringValue: String) {
            self.init(stringValue)
        }

        init?(intValue: Int) {
            nil
        }
    }
}
