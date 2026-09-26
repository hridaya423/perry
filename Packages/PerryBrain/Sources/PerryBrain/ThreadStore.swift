import Foundation

/// A Home thread (Phase 5): a persisted conversation between you and Perry.
/// Deliberately text-only — screenshots never persist beyond a turn, so a
/// thread stores question, answer text, and element *labels* only.
public struct PerryThread: Codable, Equatable, Sendable, Identifiable {
    public struct Turn: Codable, Equatable, Sendable {
        public let question: String
        public let answer: String
        /// Human-readable labels of the elements Perry marked, for context.
        public let elementLabels: [String]
        public let at: Date

        public init(question: String, answer: String, elementLabels: [String] = [], at: Date = Date()) {
            self.question = question
            self.answer = answer
            self.elementLabels = elementLabels
            self.at = at
        }
    }

    public let id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    /// Set when the thread belongs to a persistent Perry (Phase 9).
    public var perryID: String?
    /// Unsent composer text kept per thread (§4.7).
    public var draft: String
    public var turns: [Turn]

    public init(
        id: UUID = UUID(),
        title: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        perryID: String? = nil,
        draft: String = "",
        turns: [Turn] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.perryID = perryID
        self.draft = draft
        self.turns = turns
    }
}

/// JSON-file-backed thread store: one `<uuid>.json` per thread under the
/// given directory, atomic writes, newest-first listing. An actor so the
/// in-memory cache and disk can never disagree about order or presence.
public actor ThreadStore {
    public static let defaultHistoryLimit = 200

    private let directory: URL
    private let historyLimit: Int
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var cache: [UUID: PerryThread]?

    public init(directory: URL, historyLimit: Int = defaultHistoryLimit) {
        self.directory = directory
        self.historyLimit = max(1, historyLimit)
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder.dateDecodingStrategy = .iso8601
    }

    /// Newest-first by `updatedAt`.
    public func list() -> [PerryThread] {
        loadAll()
        return (cache ?? [:]).values.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func thread(id: UUID) -> PerryThread? {
        loadAll()
        return cache?[id]
    }

    @discardableResult
    public func upsert(_ thread: PerryThread) -> PerryThread {
        var t = thread
        if t.turns.count > historyLimit {
            t.turns = Array(t.turns.suffix(historyLimit))
        }
        loadAll()
        cache?[t.id] = t
        persist(t)
        return t
    }

    /// Appends a turn, bumps `updatedAt`, and derives a title from the first
    /// question when the thread is still untitled.
    @discardableResult
    public func appendTurn(
        to id: UUID,
        question: String,
        answer: String,
        elementLabels: [String] = [],
        at now: Date = Date()
    ) -> PerryThread {
        var t = thread(id: id) ?? PerryThread(id: id)
        t.turns.append(PerryThread.Turn(
            question: question, answer: answer,
            elementLabels: elementLabels, at: now
        ))
        t.updatedAt = now
        if t.title.isEmpty {
            t.title = Self.derivedTitle(from: question)
        }
        return upsert(t)
    }

    public func setDraft(_ draft: String, for id: UUID) {
        guard var t = thread(id: id) else { return }
        t.draft = draft
        t.updatedAt = Date()
        _ = upsert(t)
    }

    public func delete(id: UUID) {
        loadAll()
        cache?[id] = nil
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent("\(id.uuidString).json")
        )
    }

    // MARK: - Internals

    /// First line of the question, trimmed to a sidebar-friendly length.
    static func derivedTitle(from question: String) -> String {
        let line = question
            .components(separatedBy: .newlines).first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return String(line.prefix(60))
    }

    private func loadAll() {
        guard cache == nil else { return }
        var loaded: [UUID: PerryThread] = [:]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ))?.filter { $0.pathExtension == "json" } ?? []
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let thread = try? decoder.decode(PerryThread.self, from: data)
            else { continue }
            loaded[thread.id] = thread
        }
        cache = loaded
    }

    private func persist(_ thread: PerryThread) {
        guard let data = try? encoder.encode(thread) else { return }
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        try? data.write(
            to: directory.appendingPathComponent("\(thread.id.uuidString).json"),
            options: .atomic
        )
    }
}
