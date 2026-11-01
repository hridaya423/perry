@testable import Perry
import Foundation

final class FlakyCredentialBackend: OAuthCredentialStoreBackend, @unchecked Sendable {
    struct Refused: Error {}

    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var refusesSaves = false
    private var refusesDeletes = false

    var accounts: [String] { lock.withLock { values.keys.sorted() } }

    func refuse(saves: Bool = false, deletes: Bool = false) {
        lock.withLock {
            refusesSaves = saves
            refusesDeletes = deletes
        }
    }

    func readCredential(account: String) throws -> String? { lock.withLock { values[account] } }

    func save(_ secret: String, account: String) throws {
        try lock.withLock {
            if refusesSaves { throw Refused() }
            values[account] = secret
        }
    }

    func deleteCredential(account: String) throws {
        try lock.withLock {
            if refusesDeletes { throw Refused() }
            values[account] = nil
        }
    }
}
