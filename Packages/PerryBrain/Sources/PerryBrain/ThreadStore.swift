import Foundation

/// A Home thread (Phase 5): a persisted conversation between you and Perry.
/// Deliberately text-only — screenshots never persist beyond a turn, so a
/// thread stores question, answer text, and element *labels* only.
public struct PerryThread: Codable, Equatable, Sendable, Identifiable {
    public struct Turn: Codable, Equatable, Sendable {
        public enum Outcome: String, Codable, Sendable {
            case completed, interrupted, failed, limited
        }

        public let question: String
        public let answer: String
        public var outcome: Outcome?
        public var failureReason: String?
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

    public struct PendingTurn: Codable, Equatable, Sendable {
        public let id: UUID
        public let question: String
        public let startedAt: Date

        public init(id: UUID = UUID(), question: String, startedAt: Date = Date()) {
            self.id = id
            self.question = question
            self.startedAt = startedAt
        }
    }

    public struct WaitingInput: Codable, Equatable, Sendable, Identifiable {
        public let id: UUID
        public let text: String
        public let receivedAt: Date

        public init(id: UUID = UUID(), text: String, receivedAt: Date = Date()) {
            self.id = id
            self.text = text
            self.receivedAt = receivedAt
        }
    }

    public struct ContextSummary: Codable, Equatable, Sendable {
        public let text: String
        public let sourceTurnCount: Int
    }

    public var contextSummary: ContextSummary?
    public let id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    /// Set when the thread belongs to a persistent Perry (Phase 9).
    public var perryID: String?
    public var sourceServiceID: String?
    /// Unsent composer text kept per thread (§4.7).
    public var draft: String
    public var turns: [Turn]
    public var pendingTurn: PendingTurn?
    public var waitingInputs: [WaitingInput]?

    public init(
        id: UUID = UUID(),
        title: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        perryID: String? = nil,
        sourceServiceID: String? = nil,
        draft: String = "",
        turns: [Turn] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.perryID = perryID
        self.sourceServiceID = sourceServiceID
        self.draft = draft
        self.turns = turns
    }

    public func messages(for question: String, historyCharacterLimit: Int = 48_000) -> [ModelMessage] {
        var remaining = max(0, historyCharacterLimit)
        var recent: [Turn] = []
        for turn in turns.reversed() {
            let size = turn.question.count + turn.answer.count
            guard size <= remaining else { break }
            remaining -= size
            recent.append(turn)
        }
        var messages: [ModelMessage] = []
        for turn in recent.reversed() {
            messages.append(.user([.text(turn.question)]))
            if !turn.answer.isEmpty {
                messages.append(.assistant(text: turn.answer, toolCalls: []))
            }
        }
        messages.append(.user([.text(question)]))
        return messages
    }
}

public enum ThreadStoreError: Error, LocalizedError {
    case draftOccupied
    case unfinishedTurn
    case runMismatch
    case unreadableRecord(URL)
    case unsupportedVersion(Int)
    case contextChanged

    public var errorDescription: String? {
        switch self {
        case .draftOccupied: return "The composer already contains a draft. Keep or clear it before restoring this request."
        case .contextChanged: return "This conversation changed while Perry was preparing its context. Your messages are saved; try again."
        case .unsupportedVersion(let version): return "This conversation uses a newer storage version (\(version)). Update Perry to open it. Its file has been preserved."
        case .unfinishedTurn: return "This conversation has an unfinished task. Review it before starting another."
        case .runMismatch: return "The task no longer owns this conversation."
        case .unreadableRecord(let file): return "Couldn’t read \(file.lastPathComponent). The original file has been preserved for recovery."
        }
    }
}

/// JSON-file-backed thread store: one `<uuid>.json` per thread under the
/// given directory, atomic writes, newest-first listing. An actor so the
/// in-memory cache and disk can never disagree about order or presence.
public actor ThreadStore {
    public struct ReadIssue: Sendable, Equatable {
        public let file: URL
        public let message: String
    }

    private struct Record: Codable {
        let schemaVersion: Int
        let conversation: PerryThread
    }

    private struct RecordVersion: Decodable {
        let schemaVersion: Int?
    }

    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var cache: [UUID: PerryThread]?
    private var issues: [ReadIssue] = []
    private var directoryReadFailed = false

    public func reload() -> [PerryThread] {
        cache = nil
        issues = []
        directoryReadFailed = false
        return list()
    }

    public func readIssues() -> [ReadIssue] {
        loadAll()
        return issues
    }

    public init(directory: URL) {
        self.directory = directory
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder.dateDecodingStrategy = .iso8601
    }

    public func welcomeDraft() throws -> String {
        do {
            return try String(contentsOf: directory.appendingPathComponent("welcome.draft"), encoding: .utf8)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return ""
        }
    }

    public func setWelcomeDraft(_ text: String) throws {
        try Task.checkCancellation()
        _ = try welcomeDraft()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try text.write(to: directory.appendingPathComponent("welcome.draft"), atomically: true, encoding: .utf8)
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
    public func upsert(_ thread: PerryThread) throws -> PerryThread {
        loadAll()
        var thread = thread
        if let summary = thread.contextSummary {
            let count = summary.sourceTurnCount
            if count <= 0 || count > thread.turns.count {
                thread.contextSummary = nil
            } else if let previous = cache?[thread.id], previous.turns.prefix(count) != thread.turns.prefix(count) {
                thread.contextSummary = nil
            }
        }
        let file = directory.appendingPathComponent("\(thread.id.uuidString).json")
        if directoryReadFailed || issues.contains(where: { $0.file.lastPathComponent == file.lastPathComponent }) {
            throw ThreadStoreError.unreadableRecord(file)
        }
        try persist(thread)
        cache?[thread.id] = thread
        return thread
    }

    public func stageInput(_ input: PerryThread.WaitingInput, to id: UUID) throws {
        var thread = thread(id: id) ?? PerryThread(id: id)
        var waiting = thread.waitingInputs ?? []
        if let existing = waiting.first(where: { $0.id == input.id }) {
            guard existing.text == input.text else { throw ThreadStoreError.runMismatch }
            return
        }
        waiting.append(input)
        thread.waitingInputs = waiting
        if thread.title.isEmpty { thread.title = Self.derivedTitle(from: input.text) }
        thread.updatedAt = Date()
        _ = try upsert(thread)
    }

    public func restoreWaitingInput(_ inputID: UUID, from id: UUID) throws {
        guard var thread = thread(id: id), let input = thread.waitingInputs?.first(where: { $0.id == inputID }) else {
            throw ThreadStoreError.runMismatch
        }
        guard thread.pendingTurn == nil else { throw ThreadStoreError.unfinishedTurn }
        guard thread.draft.isEmpty else { throw ThreadStoreError.draftOccupied }
        thread.draft = input.text
        thread.waitingInputs?.removeAll { $0.id == inputID }
        thread.updatedAt = Date()
        _ = try upsert(thread)
    }

    public func removeWaitingInput(_ inputID: UUID, from id: UUID) throws {
        guard var thread = thread(id: id) else { throw ThreadStoreError.runMismatch }
        thread.waitingInputs?.removeAll { $0.id == inputID }
        thread.updatedAt = Date()
        _ = try upsert(thread)
    }

    public func beginTurn(to id: UUID, question: String, perryID: String? = nil, runID: UUID = UUID(), waitingInputID: UUID? = nil) throws -> PerryThread {
        var thread = thread(id: id) ?? PerryThread(id: id, perryID: perryID)
        guard thread.pendingTurn == nil else { throw ThreadStoreError.unfinishedTurn }
        if let waitingInputID {
            guard waitingInputID == runID,
                  let waiting = thread.waitingInputs?.first(where: { $0.id == waitingInputID }),
                  waiting.text == question else { throw ThreadStoreError.runMismatch }
            thread.waitingInputs?.removeAll { $0.id == waitingInputID }
        }
        if thread.perryID == nil { thread.perryID = perryID }
        thread.pendingTurn = PerryThread.PendingTurn(id: runID, question: question)
        if thread.title.isEmpty { thread.title = Self.derivedTitle(from: question) }
        thread.updatedAt = Date()
        return try upsert(thread)
    }

    public func finishTurn(
        to id: UUID,
        runID: UUID,
        answer: String,
        outcome: PerryThread.Turn.Outcome,
        elementLabels: [String] = [],
        failureReason: String? = nil
    ) throws {
        guard var thread = thread(id: id), let pending = thread.pendingTurn, pending.id == runID else {
            throw ThreadStoreError.runMismatch
        }
        var turn = PerryThread.Turn(question: pending.question, answer: answer, elementLabels: elementLabels)
        turn.outcome = outcome
        turn.failureReason = failureReason
        thread.turns.append(turn)
        thread.pendingTurn = nil
        if outcome == .completed {
            if thread.draft == pending.question { thread.draft = "" }
        } else if thread.draft.isEmpty {
            thread.draft = pending.question
        }
        thread.updatedAt = Date()
        _ = try upsert(thread)
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
    ) throws -> PerryThread {
        var t = thread(id: id) ?? PerryThread(id: id)
        t.turns.append(PerryThread.Turn(
            question: question, answer: answer,
            elementLabels: elementLabels, at: now
        ))
        t.updatedAt = now
        if t.title.isEmpty {
            t.title = Self.derivedTitle(from: question)
        }
        return try upsert(t)
    }

    public func saveContextSummary(_ text: String, sourceTurns: [PerryThread.Turn], to id: UUID, runID: UUID) throws {
        guard var thread = thread(id: id), thread.pendingTurn?.id == runID else { throw ThreadStoreError.runMismatch }
        guard !sourceTurns.isEmpty, thread.turns.prefix(sourceTurns.count).elementsEqual(sourceTurns) else {
            throw ThreadStoreError.contextChanged
        }
        thread.contextSummary = PerryThread.ContextSummary(text: text, sourceTurnCount: sourceTurns.count)
        _ = try upsert(thread)
    }

    public func setDraft(_ draft: String, for id: UUID) throws {
        guard var t = thread(id: id) else { return }
        t.draft = draft
        t.updatedAt = Date()
        _ = try upsert(t)
    }

    public func delete(id: UUID) throws {
        loadAll()
        for version in ["legacy", "v1"] {
            let backup = directory.appendingPathComponent("migration-backups/\(id.uuidString)-\(version).json")
            do { try FileManager.default.removeItem(at: backup) }
            catch let error as CocoaError where error.code == .fileNoSuchFile { }
        }
        try FileManager.default.removeItem(
            at: directory.appendingPathComponent("\(id.uuidString).json")
        )
        cache?[id] = nil
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
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "json" }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            cache = [:]
            return
        } catch {
            directoryReadFailed = true
            issues = [ReadIssue(file: directory, message: error.localizedDescription)]
            cache = [:]
            return
        }
        for file in files {
            do {
                let thread = try decodeRecord(Data(contentsOf: file))
                guard file.deletingPathExtension().lastPathComponent == thread.id.uuidString else {
                    throw ThreadStoreError.unreadableRecord(file)
                }
                loaded[thread.id] = thread
            } catch {
                issues.append(ReadIssue(file: file, message: error.localizedDescription))
            }
        }
        cache = loaded
    }

    private func decodeRecord(_ data: Data) throws -> PerryThread {
        guard let version = try decoder.decode(RecordVersion.self, from: data).schemaVersion else {
            return try decoder.decode(PerryThread.self, from: data)
        }
        guard version == 1 || version == 2 else { throw ThreadStoreError.unsupportedVersion(version) }
        return try decoder.decode(Record.self, from: data).conversation
    }

    private func preservePreviousRecord(at file: URL) throws {
        let original: Data
        do { original = try Data(contentsOf: file) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return }
        _ = try decodeRecord(original)
        let version = try decoder.decode(RecordVersion.self, from: original).schemaVersion
        guard version != 2 else { return }
        let backups = directory.appendingPathComponent("migration-backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let suffix = version.map { "v\($0)" } ?? "legacy"
        let backup = backups.appendingPathComponent(file.deletingPathExtension().lastPathComponent + "-\(suffix).json")
        if FileManager.default.fileExists(atPath: backup.path) {
            guard try Data(contentsOf: backup) == original else { throw ThreadStoreError.unreadableRecord(backup) }
        } else {
            try original.write(to: backup, options: .atomic)
        }
    }

    private func persist(_ thread: PerryThread) throws {
        let data = try encoder.encode(Record(schemaVersion: 2, conversation: thread))
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let file = directory.appendingPathComponent("\(thread.id.uuidString).json")
        try preservePreviousRecord(at: file)
        try data.write(to: file, options: .atomic)
    }
}
