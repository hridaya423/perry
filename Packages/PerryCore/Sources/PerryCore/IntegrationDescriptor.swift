import Foundation

public struct CredentialReference: Codable, Equatable, Sendable {
    public let service: String
    public let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    private enum CodingKeys: String, CodingKey {
        case service
        case account
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        service = try values.decode(String.self, forKey: .service)
        account = try values.decode(String.self, forKey: .account)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(service, forKey: .service)
        try values.encode(account, forKey: .account)
    }
}

public struct IntegrationDescriptor: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let credentialReference: CredentialReference?

    public init(
        id: String,
        displayName: String,
        credentialReference: CredentialReference? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.credentialReference = credentialReference
    }
}
