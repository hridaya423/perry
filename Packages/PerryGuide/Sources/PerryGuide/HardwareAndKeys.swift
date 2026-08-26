import Foundation
import Security

/// PRD §4: BYOK keys live in Keychain, never in plists or defaults.
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

    public func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// PRD §4 runtime ladder: local tier is gated by a hardware probe. Below the
/// floor the tier shows "This Mac can't run this well" with specifics.
public struct HardwareProbe: Sendable {
    public struct Report: Equatable, Sendable {
        public let chipName: String
        public let memoryGB: Int
        public let passesFloor: Bool
        public let reasonIfBelow: String?
    }

    public init() {}

    /// Floor per PRD: M-series with 16GB+ unified memory for 4–7B quantized.
    public func evaluate(
        chipName: String,
        physicalMemoryBytes: UInt64
    ) -> HardwareProbe.Report {
        let memoryGB = Int(physicalMemoryBytes / (1024 * 1024 * 1024))
        let isAppleSilicon = chipName.lowercased().contains("apple")
        let memoryOK = memoryGB >= 16
        let passes = isAppleSilicon && memoryOK
        let reason: String?
        if !isAppleSilicon {
            reason = "\(chipName) isn't Apple silicon; on-device models need unified memory."
        } else if !memoryOK {
            reason = "\(memoryGB) GB of unified memory is under the 16 GB floor for usable 4–7B quantized models."
        } else {
            reason = nil
        }
        return Report(chipName: chipName, memoryGB: memoryGB, passesFloor: passes, reasonIfBelow: reason)
    }

    public func evaluateCurrent() -> HardwareProbe.Report {
        var size: UInt64 = 0
        var sizeLength: Int = MemoryLayout<UInt64>.size
        var mib: [Int32] = [CTL_HW, HW_MEMSIZE]
        sysctl(&mib, 2, &size, &sizeLength, nil, 0)
        var nameMax: [CChar] = Array(repeating: 0, count: 256)
        var nameLen = nameMax.count
        sysctlbyname("machdep.cpu.brand_string", &nameMax, &nameLen, nil, 0)
        let chip = String(cString: nameMax)
        return evaluate(chipName: chip, physicalMemoryBytes: UInt64(size))
    }
}
