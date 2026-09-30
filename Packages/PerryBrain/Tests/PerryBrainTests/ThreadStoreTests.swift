import XCTest
@testable import PerryBrain

final class ThreadStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store() -> ThreadStore {
        ThreadStore(directory: directory)
    }

    func testVersionOneIsBackedUpBeforeWaitingInputMigration() async throws {
        let store = store()
        let thread = PerryThread(draft: "Existing draft", turns: [.init(question: "Earlier", answer: "Saved")])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = try JSONSerialization.jsonObject(with: encoder.encode(thread))
        let original = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "conversation": payload])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(thread.id.uuidString).json")
        try original.write(to: file)
        let input = PerryThread.WaitingInput(text: "Guide me")
        try await store.stageInput(input, to: thread.id)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("migration-backups/\(thread.id.uuidString)-v1.json")), original)
        let saved = await ThreadStore(directory: directory).thread(id: thread.id)
        XCTAssertEqual(saved?.draft, thread.draft)
        XCTAssertEqual(saved?.turns.first?.answer, "Saved")
        XCTAssertEqual(saved?.waitingInputs?.first?.id, input.id)
        XCTAssertNil(saved?.pendingTurn)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(record["schemaVersion"] as? Int, 2)
        try await store.delete(id: thread.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("migration-backups/\(thread.id.uuidString)-v1.json").path))
    }

    func testWaitingInputSurvivesRestartWithoutReplacingDraftOrStartingWork() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ThreadStore(directory: directory)
        let thread = try await store.upsert(PerryThread(draft: "Separate draft"))
        let input = PerryThread.WaitingInput(text: "show me how to save")
        try await store.stageInput(input, to: thread.id)
        let restarted = ThreadStore(directory: directory)
        let saved = await restarted.thread(id: thread.id)
        XCTAssertEqual(saved?.draft, "Separate draft")
        XCTAssertEqual(saved?.waitingInputs?.map(\.id), [input.id])
        XCTAssertEqual(saved?.waitingInputs?.map(\.text), [input.text])
        XCTAssertNil(saved?.pendingTurn)
        XCTAssertTrue(saved?.turns.isEmpty == true)
        do {
            try await restarted.restoreWaitingInput(input.id, from: thread.id)
            XCTFail("Restoration overwrote another draft")
        } catch ThreadStoreError.draftOccupied {}
        try await restarted.setDraft("", for: thread.id)
        try await restarted.restoreWaitingInput(input.id, from: thread.id)
        let restored = await ThreadStore(directory: directory).thread(id: thread.id)
        XCTAssertEqual(restored?.draft, input.text)
        XCTAssertTrue(restored?.waitingInputs?.isEmpty == true)
        XCTAssertNil(restored?.pendingTurn)
    }

    func testWaitingInputPromotesAtomicallyOnlyForItsExactRunAndText() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ThreadStore(directory: directory)
        let id = UUID()
        let input = PerryThread.WaitingInput(text: "Guide me")
        try await store.stageInput(input, to: id)
        do {
            _ = try await store.beginTurn(to: id, question: "Different task", runID: input.id, waitingInputID: input.id)
            XCTFail("Changed input reused a saved identity")
        } catch ThreadStoreError.runMismatch {}
        _ = try await store.beginTurn(to: id, question: input.text, runID: input.id, waitingInputID: input.id)
        let saved = await ThreadStore(directory: directory).thread(id: id)
        XCTAssertEqual(saved?.pendingTurn?.id, input.id)
        XCTAssertTrue(saved?.waitingInputs?.isEmpty == true)
        XCTAssertTrue(saved?.turns.isEmpty == true)
    }

    func testDiscardedWaitingInputCannotStartFromStaleCallback() async throws {
        let store = store()
        let id = UUID()
        let input = PerryThread.WaitingInput(text: "Guide me")
        try await store.stageInput(input, to: id)
        try await store.removeWaitingInput(input.id, from: id)
        do {
            _ = try await store.beginTurn(to: id, question: input.text, runID: input.id, waitingInputID: input.id)
            XCTFail("Discarded request started")
        } catch ThreadStoreError.runMismatch {}
        let saved = await store.thread(id: id)
        XCTAssertNil(saved?.pendingTurn)
        XCTAssertTrue(saved?.turns.isEmpty == true)
    }

    func testLegacyConversationIsBackedUpBeforeFirstVersionedWrite() async throws {
        let original = PerryThread(title: "Existing conversation", turns: [.init(question: "Remember Cedar", answer: "Cedar")])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let legacy = try encoder.encode(original)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(original.id.uuidString).json")
        try legacy.write(to: file)
        let s = store()
        let loaded = await s.thread(id: original.id)
        XCTAssertEqual(loaded?.turns.first?.question, "Remember Cedar")
        try await s.setDraft("A follow-up", for: original.id)
        let backup = directory.appendingPathComponent("migration-backups/\(original.id.uuidString)-legacy.json")
        XCTAssertEqual(try Data(contentsOf: backup), legacy)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(record["schemaVersion"] as? Int, 2)
        let restored = await store().thread(id: original.id)
        XCTAssertEqual(restored?.draft, "A follow-up")
        XCTAssertEqual(restored?.turns.count, 1)
        try await s.delete(id: original.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        let deleted = await store().thread(id: original.id)
        XCTAssertNil(deleted)
    }

    func testMigrationBackupFailurePreservesLegacyFileAndCache() async throws {
        let original = PerryThread(title: "Legacy")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let legacy = try encoder.encode(original)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(original.id.uuidString).json")
        try legacy.write(to: file)
        try Data("blocked".utf8).write(to: directory.appendingPathComponent("migration-backups"))
        let s = store()
        do {
            try await s.setDraft("Should not be acknowledged", for: original.id)
            XCTFail("Expected backup failure")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: file), legacy)
        let retained = await s.thread(id: original.id)
        XCTAssertEqual(retained?.draft, "")
    }

    func testFutureRecordIsPreservedAndCannotBeOverwritten() async throws {
        let id = UUID()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(id.uuidString).json")
        let original = Data(#"{"schemaVersion":99,"conversation":{}}"#.utf8)
        try original.write(to: file)
        let s = store()
        let issues = await s.readIssues()
        XCTAssertEqual(issues.count, 1)
        do {
            _ = try await s.upsert(PerryThread(id: id))
            XCTFail("Expected unsupported record rejection")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testWelcomeDraftSurvivesRestartAndDoesNotCreateAConversation() async throws {
        let s = store()
        try await s.setWelcomeDraft("An unfinished first question")
        let restored = try await store().welcomeDraft()
        let threads = await store().list()
        XCTAssertEqual(restored, "An unfinished first question")
        XCTAssertTrue(threads.isEmpty)
        try await s.setWelcomeDraft("")
        let cleared = try await store().welcomeDraft()
        XCTAssertEqual(cleared, "")
    }

    func testUnreadableWelcomeDraftIsNotOverwritten() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("welcome.draft")
        let original = Data([0xff, 0xfe, 0xfd])
        try original.write(to: file)
        do {
            try await store().setWelcomeDraft("Replacement")
            XCTFail("The unreadable original must be preserved")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testWelcomeDraftWriteFailureIsReported() async throws {
        try Data("blocked".utf8).write(to: directory)
        do {
            try await store().setWelcomeDraft("Keep this input")
            XCTFail("The failed save must be visible to the caller")
        } catch {}
    }

    func testAppendTurnCreatesAndPersists() async throws {
        let s = store()
        let id = UUID()
        let t = try await s.appendTurn(to: id, question: "what's this button?", answer: "The save button.")
        XCTAssertEqual(t.turns.count, 1)
        XCTAssertEqual(t.title, "what's this button?")
        let reloaded = ThreadStore(directory: directory)
        let answer = await reloaded.thread(id: id)?.turns.first?.answer
        XCTAssertEqual(answer, "The save button.")
    }

    func testListIsNewestFirst() async throws {
        let s = store()
        let older = try await s.appendTurn(to: UUID(), question: "old", answer: "a",
                                       at: Date(timeIntervalSince1970: 100))
        let newer = try await s.appendTurn(to: UUID(), question: "new", answer: "b",
                                       at: Date(timeIntervalSince1970: 200))
        let ids = await s.list().map(\.id)
        XCTAssertEqual(ids, [newer.id, older.id])
    }

    func testTitleOnlyFromFirstTurn() async throws {
        let s = store()
        let id = UUID()
        _ = try await s.appendTurn(to: id, question: "first q", answer: "a")
        _ = try await s.appendTurn(to: id, question: "second q", answer: "b")
        let title = await s.thread(id: id)?.title
        XCTAssertEqual(title, "first q")
    }

    func testConversationRetainsSourceTurns() async throws {
        let s = store()
        let id = UUID()
        for i in 1...4 {
            _ = try await s.appendTurn(to: id, question: "q\(i)", answer: "a\(i)")
        }
        let questions = await s.thread(id: id)?.turns.map(\.question)
        XCTAssertEqual(questions, ["q1", "q2", "q3", "q4"])
    }

    func testDraftPersistsPerThread() async throws {
        let s = store()
        let id = UUID()
        _ = try await s.appendTurn(to: id, question: "q", answer: "a")
        try await s.setDraft("half-typed reply", for: id)
        let draft = await s.thread(id: id)?.draft
        XCTAssertEqual(draft, "half-typed reply")
    }

    func testDeleteRemovesFileAndCacheEntry() async throws {
        let s = store()
        let id = UUID()
        _ = try await s.appendTurn(to: id, question: "q", answer: "a")
        try await s.delete(id: id)
        let gone = await s.thread(id: id)
        XCTAssertNil(gone)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("\(id.uuidString).json").path))
    }

    func testCorruptRecordIsReportedAndCannotBeOverwritten() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        let file = directory.appendingPathComponent("\(id.uuidString).json")
        let original = Data("not json".utf8)
        try original.write(to: file)
        let s = store()
        let valid = try await s.appendTurn(to: UUID(), question: "Still available", answer: "Yes")
        let threads = await s.list()
        XCTAssertEqual(threads.map(\.id), [valid.id])
        let issues = await s.readIssues()
        XCTAssertEqual(issues.map { $0.file.lastPathComponent }, [file.lastPathComponent])
        do {
            _ = try await s.beginTurn(to: id, question: "Do not replace the original")
            XCTFail("Unreadable records must be preserved")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testDerivedTitleTruncatesAndStripsNewlines() {
        let q = "  what does this do?\nsecond line  "
        XCTAssertEqual(ThreadStore.derivedTitle(from: q), "what does this do?")
        let long = String(repeating: "x", count: 100)
        XCTAssertEqual(ThreadStore.derivedTitle(from: long).count, 60)
    }

    func testFailedWriteDoesNotPublishAnUnsavedTurn() async throws {
        let s = store()
        let id = UUID()
        let saved = try await s.appendTurn(to: id, question: "Keep this", answer: "Saved")
        try FileManager.default.removeItem(at: directory)
        try Data("blocked".utf8).write(to: directory)

        do {
            _ = try await s.appendTurn(to: id, question: "Unsaved", answer: "Must not appear saved")
            XCTFail("An unwritable store must report failure")
        } catch {}

        let cached = await s.thread(id: id)
        XCTAssertEqual(cached, saved)
    }

    func testFailedDeleteKeepsTheConversationAvailable() async throws {
        let s = store()
        let id = UUID()
        let saved = try await s.appendTurn(to: id, question: "Keep this", answer: "Saved")
        try FileManager.default.removeItem(at: directory)
        try Data("blocked".utf8).write(to: directory)

        do {
            try await s.delete(id: id)
            XCTFail("A failed deletion must be reported")
        } catch {}

        let cached = await s.thread(id: id)
        XCTAssertEqual(cached, saved)
    }

    func testPendingTurnSurvivesRestartAndPreventsAnotherRun() async throws {
        let id = UUID()
        let thread = try await store().beginTurn(to: id, question: "Rename the selected files")
        let reloaded = store()
        let pending = await reloaded.thread(id: id)?.pendingTurn
        XCTAssertEqual(pending?.id, thread.pendingTurn?.id)
        XCTAssertEqual(pending?.question, thread.pendingTurn?.question)
        do {
            _ = try await reloaded.beginTurn(to: id, question: "Do it again")
            XCTFail("An unreconciled task must not run again")
        } catch ThreadStoreError.unfinishedTurn {}
    }

    func testFinishingTurnPersistsOutcomeOnceAndPreservesNewDraft() async throws {
        let s = store()
        let id = UUID()
        let thread = try await s.beginTurn(to: id, question: "Summarize this")
        let runID = try XCTUnwrap(thread.pendingTurn?.id)
        try await s.setDraft("Now make it shorter", for: id)
        try await s.finishTurn(to: id, runID: runID, answer: "Summary", outcome: .completed)
        let saved = await store().thread(id: id)
        XCTAssertNil(saved?.pendingTurn)
        XCTAssertEqual(saved?.turns.count, 1)
        XCTAssertEqual(saved?.turns.first?.outcome, .completed)
        XCTAssertEqual(saved?.draft, "Now make it shorter")
        do {
            try await s.finishTurn(to: id, runID: runID, answer: "Duplicate", outcome: .completed)
            XCTFail("A finished run must not append a second result")
        } catch ThreadStoreError.runMismatch {}
    }

    func testUnsuccessfulOutcomesPreserveRequestAfterRestart() async throws {
        let s = store()
        for outcome in [PerryThread.Turn.Outcome.interrupted, .failed, .limited] {
            for initialDraft in ["", "Keep my request", "A newer follow-up"] {
                let id = UUID()
                _ = try await s.upsert(PerryThread(id: id, draft: initialDraft))
                let started = try await s.beginTurn(to: id, question: "Keep my request")
                try await s.finishTurn(to: id, runID: XCTUnwrap(started.pendingTurn?.id), answer: "Partial", outcome: outcome)
                let restored = await store().thread(id: id)
                XCTAssertEqual(restored?.draft, initialDraft.isEmpty ? "Keep my request" : initialDraft)
                XCTAssertEqual(restored?.turns.first?.answer, "Partial")
                XCTAssertEqual(restored?.turns.first?.outcome, outcome)
                XCTAssertNil(restored?.pendingTurn)
            }
        }
    }

    func testSuccessfulOutcomeClearsOnlyItsOwnDraft() async throws {
        let s = store()
        for initialDraft in ["Original request", "A newer follow-up"] {
            let id = UUID()
            _ = try await s.upsert(PerryThread(id: id, draft: initialDraft))
            let started = try await s.beginTurn(to: id, question: "Original request")
            try await s.finishTurn(to: id, runID: XCTUnwrap(started.pendingTurn?.id), answer: "Done", outcome: .completed)
            let restored = await store().thread(id: id)
            XCTAssertEqual(restored?.draft, initialDraft == "Original request" ? "" : initialDraft)
        }
    }

    func testContextRetainsRecentPairsAndCurrentRequestWithinBudget() {
        let thread = PerryThread(turns: [
            .init(question: "old question", answer: "old answer"),
            .init(question: "name?", answer: "Perry")
        ])
        XCTAssertEqual(thread.messages(for: "spell it", historyCharacterLimit: 10), [
            .user([.text("name?")]),
            .assistant(text: "Perry", toolCalls: []),
            .user([.text("spell it")])
        ])
        XCTAssertEqual(thread.turns.count, 2)
    }
}
