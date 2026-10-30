import Foundation
import PerryBrain
import PerryCore

struct OAuthConfiguration: Sendable {
    static let defaultRedirectURI = URL(string: "dev.perry.perry:/oauth/callback")!

    let clientID: String
    let clientSecret: String?
    let redirectURI: URL
    let scopes: [String]

    init(
        clientID: String,
        clientSecret: String? = nil,
        redirectURI: URL = OAuthConfiguration.defaultRedirectURI,
        scopes: [String]
    ) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.redirectURI = redirectURI
        self.scopes = scopes
    }
}


struct OAuthToken: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let tokenType: String
    let expiresAt: Date?
    let scopes: Set<String>

    init(
        accessToken: String,
        refreshToken: String? = nil,
        tokenType: String = "Bearer",
        expiresAt: Date? = nil,
        scopes: Set<String> = []
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenType = tokenType
        self.expiresAt = expiresAt
        self.scopes = scopes
    }

    private enum CodingKeys: String, CodingKey {
        case accessToken, refreshToken, tokenType, expiresAt, scopes
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try values.decode(String.self, forKey: .accessToken)
        refreshToken = try values.decodeIfPresent(String.self, forKey: .refreshToken)
        tokenType = try values.decode(String.self, forKey: .tokenType)
        expiresAt = try values.decodeIfPresent(Date.self, forKey: .expiresAt)
        scopes = try values.decodeIfPresent(Set<String>.self, forKey: .scopes) ?? []
    }

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date()
    }

    var needsRefresh: Bool {
        guard let expiresAt else { return false }
        return expiresAt <= Date().addingTimeInterval(60)
    }
}

struct StoredOAuthCredential: Codable, Equatable, Sendable {
    let token: OAuthToken
    let clientID: String
    let clientSecret: String?
    let grantedScopes: Set<String>

    init(
        token: OAuthToken,
        clientID: String,
        clientSecret: String?,
        grantedScopes: Set<String>? = nil
    ) {
        self.token = token
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.grantedScopes = grantedScopes ?? token.scopes
    }

    private enum CodingKeys: String, CodingKey {
        case token, clientID, clientSecret, grantedScopes
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        token = try values.decode(OAuthToken.self, forKey: .token)
        clientID = try values.decode(String.self, forKey: .clientID)
        clientSecret = try values.decodeIfPresent(String.self, forKey: .clientSecret)
        grantedScopes = try values.decodeIfPresent(Set<String>.self, forKey: .grantedScopes) ?? token.scopes
    }
}

protocol OAuthCredentialStoreBackend: Sendable {
    func readCredential(account: String) throws -> String?
    func save(_ secret: String, account: String) throws
    func deleteCredential(account: String) throws
}

extension KeychainStore: OAuthCredentialStoreBackend {
    func readCredential(account: String) throws -> String? {
        try readChecked(account: account)
    }

    func deleteCredential(account: String) throws {
        try deleteChecked(account: account)
    }
}

enum OAuthCredentialStoreError: Error, Equatable, LocalizedError {
    case keychainUnavailable(String)
    case malformedCredential(String)

    var errorDescription: String? {
        switch self {
        case .keychainUnavailable(let account):
            return "I couldn’t read the saved sign-in for \(account). Check Keychain access and try again."
        case .malformedCredential(let account):
            return "The saved credential for \(account) is damaged. Disconnect and reconnect this integration."
        }
    }
}

actor OAuthCredentialStore {
    private let backend: any OAuthCredentialStoreBackend

    init(keychain: KeychainStore = KeychainStore(service: "dev.perry.integrations")) {
        backend = keychain
    }

    init(backend: any OAuthCredentialStoreBackend) {
        self.backend = backend
    }

    func load(for definition: RemoteIntegrationDefinition) throws -> StoredOAuthCredential? {
        let encoded: String?
        do {
            encoded = try backend.readCredential(account: definition.credentialAccount)
        } catch {
            throw OAuthCredentialStoreError.keychainUnavailable(definition.credentialAccount)
        }
        guard let data = encoded?.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        if let credential = try? decoder.decode(StoredOAuthCredential.self, from: data) { return credential }
        if let token = try? decoder.decode(OAuthToken.self, from: data) {
            return StoredOAuthCredential(token: token, clientID: "", clientSecret: nil)
        }
        throw OAuthCredentialStoreError.malformedCredential(definition.credentialAccount)
    }

    func save(_ credential: StoredOAuthCredential, for definition: RemoteIntegrationDefinition) throws {
        let data = try JSONEncoder().encode(credential)
        try backend.save(String(decoding: data, as: UTF8.self), account: definition.credentialAccount)
    }

    func delete(for definition: RemoteIntegrationDefinition) throws {
        do {
            try backend.deleteCredential(account: definition.credentialAccount)
        } catch {
            throw OAuthCredentialStoreError.keychainUnavailable(definition.credentialAccount)
        }
    }
}

enum OAuthError: Error, LocalizedError {
    case invalidClient
    case invalidClientSecret
    case cancelled
    case invalidCallback
    case callbackMissingCode
    case providerReturned(String)
    case stateMismatch
    case tokenExchangeFailed(Int)
    case tokenResponseInvalid
    case refreshFailed(Int)
    case deviceCodeExpired

    var errorDescription: String? {
        switch self {
        case .invalidClient: return "OAuth client ID is missing."
        case .invalidClientSecret: return "This provider requires an OAuth client secret."
        case .cancelled: return "OAuth authorization was cancelled."
        case .invalidCallback: return "OAuth returned to an unexpected callback URL."
        case .callbackMissingCode: return "OAuth callback did not include an authorization code."
        case .providerReturned(let message): return message
        case .stateMismatch: return "OAuth state did not match the request."
        case .tokenExchangeFailed(let status): return "Sign-in didn’t finish (error \(status)). Try connecting again."
        case .tokenResponseInvalid: return "OAuth token response was invalid."
        case .refreshFailed(let status): return "Your sign-in expired (error \(status)). Connect the app again."
        case .deviceCodeExpired: return "The sign-in code expired before it was approved. Try connecting again."
        }
    }
}
