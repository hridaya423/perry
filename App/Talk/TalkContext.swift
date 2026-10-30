import Foundation

struct TalkContextKey: Hashable {
    var processID: Int32
    var windowID: Int64
}

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

    static func isResetPhrase(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return ["new topic", "new subject", "different question", "forget that"]
            .contains { lowered.contains($0) }
    }
}
