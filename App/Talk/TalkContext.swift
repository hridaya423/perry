import Foundation
import PerryGuide

struct TalkContextKey: Hashable {
    var processID: Int32
    var windowID: Int64
}

/// Follow-up context for Talk: one SpatialConversation per app window, kept for
/// ten minutes after its last use (plan §7 Phase 2.5). "New topic" resets it.
/// Memory only — nothing is persisted.
@MainActor
final class TalkContextStore {
    nonisolated static let defaultTTL: TimeInterval = 600

    private struct Entry {
        var conversation: SpatialConversation
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

    func conversation(for key: TalkContextKey) -> SpatialConversation {
        guard var entry = entries[key], now() - entry.lastUsedAt <= ttl else {
            entries[key] = Entry(conversation: SpatialConversation(), lastUsedAt: now())
            return SpatialConversation()
        }
        entry.lastUsedAt = now()
        entries[key] = entry
        return entry.conversation
    }

    func update(_ key: TalkContextKey, conversation: SpatialConversation) {
        entries[key] = Entry(conversation: conversation, lastUsedAt: now())
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
