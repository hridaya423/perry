import Foundation
import Security

/// BYOK keys live in the Keychain, never in plists or defaults.
public struct KeychainStore: Sendable {
    public enum KeychainError: Error, Equatable {
        case unhandled(OSStatus)
    }

    private let service: String

    public init(service: String = "dev.perry.keys") {
        self.service = service
    }

    public func save(_ secret: String, account: String) throws {
        let data = Data(secret.utf8)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unhandled(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.unhandled(status)
        }
    }

    public func readChecked(account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.unhandled(status)
        }
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.unhandled(errSecDecode)
        }
        return value
    }

    public func deleteChecked(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status)
        }
    }

    public func accounts() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess,
              let attributes = result as? [[String: Any]] else {
            throw KeychainError.unhandled(status == errSecSuccess ? errSecDecode : status)
        }
        let accounts = try attributes.map { attributes in
            guard let account = attributes[kSecAttrAccount as String] as? String,
                  !account.isEmpty else {
                throw KeychainError.unhandled(errSecDecode)
            }
            return account
        }
        return Array(Set(accounts)).sorted()
    }
}
