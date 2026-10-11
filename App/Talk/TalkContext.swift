import Foundation

struct TalkContextKey: Hashable {
    var processID: Int32
    var windowID: Int64
}

/// Follow-up context for Talk: one conversation thread per app window, kept for
/// ten minutes after its last use (plan §7 Phase 2.5). "New topic" resets it.
/// Memory only — nothing is persisted.
@MainActor
final class TalkContextStore {
    nonisolated static let defaultTTL: TimeInterval = 600

    private struct Entry {
        var threadID: UUID
        var lastUsedAt: TimeInterval
    }

    private var entries: [TalkContextKey: Entry] = [:]
    private let now: () -> TimeInterval
    private let ttl: TimeInterval

    init(now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
         ttl: TimeInterval = TalkContextStore.defaultTTL) {
        self.now = now
        self.ttl = ttl
    }

    /// The window's live thread, or nil when none exists or the last turn is
    /// older than the TTL. A hit refreshes `lastUsedAt`.
    func thread(for key: TalkContextKey) -> UUID? {
        guard let entry = entries[key], now() - entry.lastUsedAt <= ttl else {
            entries.removeValue(forKey: key)
            return nil
        }
        entries[key] = entry
        entries[key]?.lastUsedAt = now()
        return entry.threadID
    }

    func record(_ key: TalkContextKey, threadID: UUID) {
        entries[key] = Entry(threadID: threadID, lastUsedAt: now())
    }

    func reset(_ key: TalkContextKey) {
        entries.removeValue(forKey: key)
    }

    func resetAll() {
        entries.removeAll()
    }

    /// Phrases that discard the window's follow-up context.
    static func isResetPhrase(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return ["new topic", "new subject", "different question", "forget that"]
            .contains { lowered.contains($0) }
    }
}
