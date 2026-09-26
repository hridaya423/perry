import Foundation

/// Per-thread "always allow" grants for agent tool calls (Phase 7 consent:
/// "Allow once / Always for this thread / Not now"). Scope is the thread ID —
/// a Perry's thread inherits its grants because threads carry `perryID`.
/// Red-tier tools are never auto-approved; they always require the card's
/// typed confirmation.
final class AgentConsentStore: @unchecked Sendable {
    static let shared = AgentConsentStore()

    private let defaults = UserDefaults.standard
    private let key = "perry.agentConsent.v1"
    private let lock = NSLock()

    /// scope → granted tool names.
    private var grants: [String: Set<String>] {
        get {
            lock.lock()
            defer { lock.unlock() }
            let raw = defaults.dictionary(forKey: key) as? [String: [String]] ?? [:]
            return raw.mapValues { Set($0) }
        }
        set {
            lock.lock()
            defaults.set(newValue.mapValues { Array($0) }, forKey: key)
            lock.unlock()
        }
    }

    func isGranted(scope: String, tool: String) -> Bool {
        grants[scope]?.contains(tool) ?? false
    }

    func grant(scope: String, tool: String) {
        var all = grants
        all[scope, default: []].insert(tool)
        grants = all
    }

    func revoke(scope: String, tool: String) {
        var all = grants
        all[scope]?.remove(tool)
        grants = all
    }

    func revokeAll(scope: String) {
        var all = grants
        all.removeValue(forKey: scope)
        grants = all
    }
}
