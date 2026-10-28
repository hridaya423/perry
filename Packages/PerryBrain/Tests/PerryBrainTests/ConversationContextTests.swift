import XCTest
@testable import PerryBrain

final class ConversationContextTests: XCTestCase {
    func testImageCannotBypassTextContextBudget() throws {
        let request = ModelRequest(messages: [.user([
            .image(data: Data([1, 2]), mimeType: "image/png"),
            .text(String(repeating: "x", count: 8192))
        ])], maxOutputTokens: 1024)
        XCTAssertThrowsError(try request.reservingOutput(in: 4096))
        XCTAssertThrowsError(try request.remainingInputBudget(in: 4096))
        let small = ModelRequest(messages: [.user([
            .image(data: Data([1, 2]), mimeType: "image/png"), .text("Save")
        ])], maxOutputTokens: 1024)
        let available = try XCTUnwrap(small.remainingInputBudget(in: 4096))
        XCTAssertGreaterThan(available, 0)
        XCTAssertLessThan(available, 4096 - 1024)
    }

    private func fixture() throws -> (URL, ThreadStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, ThreadStore(directory: root))
    }

    private func longThread() -> PerryThread {
        PerryThread(turns: (0..<10).map { index in
            .init(question: "Question \(index): " + String(repeating: "q", count: 190), answer: String(repeating: "a", count: 200))
        })
    }

    func testDeferredSummaryAnswersImmediatelyAndCondensesAfterward() async throws {
        let (root, store) = try fixture()
        let original = longThread()
        _ = try await store.upsert(original)
        let thread = try await store.beginTurn(to: original.id, question: "Continue")
        let runID = try XCTUnwrap(thread.pendingTurn?.id)
        let provider = ScriptedProvider(responses: Array(repeating: [.textDelta("Condensed."), .done(.endTurn)], count: 20))
        let prepared = try await ConversationContext().prepareDeferringSummary(
            thread: thread, question: "Continue", runID: runID, store: store, provider: provider, historyByteLimit: 2_048
        )
        // Hot path untouched: no condensation round-trips happened inline.
        XCTAssertTrue(provider.requests.isEmpty)
        XCTAssertEqual(prepared.messages.last, .user([.text("Continue")]))
        let maintenance = try XCTUnwrap(prepared.maintenance)
        try await maintenance()
        let reloaded = await store.thread(id: thread.id)
        let after = try XCTUnwrap(reloaded)
        XCTAssertNotNil(after.contextSummary?.text)
        XCTAssertGreaterThan(after.contextSummary?.sourceTurnCount ?? 0, 0)
        // And the next prepare hits the saved summary with no provider work.
        let unused = ScriptedProvider(responses: [])
        let repeated = try await ConversationContext().prepareDeferringSummary(
            thread: after, question: "Again", runID: runID, store: store, provider: unused, historyByteLimit: 2_048
        )
        XCTAssertNil(repeated.maintenance)
        XCTAssertTrue(unused.requests.isEmpty)
        _ = root
    }

    /// H5 regression: AgentCoordinator runs deferred maintenance *after*
    /// finishTurn cleared pendingTurn — the summary save must land on a
    /// quiescent thread. A write attributed to a different in-flight turn is
    /// still rejected.
    func testSummarySaveAfterTurnCompletion() async throws {
        let (root, store) = try fixture()
        let original = longThread()
        _ = try await store.upsert(original)
        let thread = try await store.beginTurn(to: original.id, question: "Continue")
        let runID = try XCTUnwrap(thread.pendingTurn?.id)
        try await store.finishTurn(to: thread.id, runID: runID, answer: "Done.", outcome: .completed)

        let reloaded = await store.thread(id: thread.id)
        let finished = try XCTUnwrap(reloaded)
        let covered = Array(finished.turns.prefix(4))
        try await store.saveContextSummary("Cedar", sourceTurns: covered, to: thread.id, runID: runID)
        let saved = await store.thread(id: thread.id)
        XCTAssertEqual(saved?.contextSummary?.text, "Cedar")

        // A stale run's write must not land while another turn is in flight.
        _ = try await store.beginTurn(to: thread.id, question: "Next")
        do {
            try await store.saveContextSummary("Stale Cedar", sourceTurns: covered, to: thread.id, runID: runID)
            XCTFail("expected runMismatch")
        } catch {
            guard case ThreadStoreError.runMismatch = error else { return XCTFail("expected runMismatch, got \(error)") }
        }
        _ = root
    }

    func testSummarySurvivesRestartAndRetainsSourceTurns() async throws {
        let (root, store) = try fixture()
        let original = longThread()
        _ = try await store.upsert(original)
        let thread = try await store.beginTurn(to: original.id, question: "Continue")
        let runID = try XCTUnwrap(thread.pendingTurn?.id)
        let provider = ScriptedProvider(responses: Array(repeating: [.textDelta("Remember Cedar; the previous rename was interrupted."), .done(.endTurn)], count: 20))
        let messages = try await ConversationContext().prepare(thread: thread, question: "Continue", runID: runID, store: store, provider: provider, historyByteLimit: 2_048)
        XCTAssertEqual(messages.last, .user([.text("Continue")]))
        XCTAssertTrue(provider.requests.allSatisfy { $0.tools.isEmpty })
        let savedThread = await ThreadStore(directory: root).thread(id: thread.id)
        let restored = try XCTUnwrap(savedThread)
        XCTAssertEqual(restored.turns.count, original.turns.count)
        XCTAssertEqual(restored.turns.map(\.question), original.turns.map(\.question))
        XCTAssertEqual(restored.contextSummary?.sourceTurnCount, 7)
        let unused = ScriptedProvider(responses: [])
        let repeated = try await ConversationContext().prepare(thread: restored, question: "Continue", runID: runID, store: store, provider: unused, historyByteLimit: 2_048)
        XCTAssertEqual(repeated, messages)
        XCTAssertTrue(unused.requests.isEmpty)
    }

    func testOriginalFactsAndCorrectionsRemainAvailableBesideLossySummary() async throws {
        let (_, store) = try fixture()
        var turns = [PerryThread.Turn(question: "The Orchid project ships Thursday.", answer: "Recorded.")]
        turns += longThread().turns
        turns.append(.init(question: "Correction: the Orchid project ships Friday, not Thursday.", answer: "Updated."))
        turns += longThread().turns
        let original = try await store.upsert(PerryThread(turns: turns))
        let question = "When does the Orchid project ship?"
        let thread = try await store.beginTurn(to: original.id, question: question)
        let provider = ScriptedProvider(responses: Array(repeating: [.textDelta("The garden is quiet."), .done(.endTurn)], count: 40), capacity: 4096)
        let base = ModelRequest(messages: [.user([.text(question)])], maxOutputTokens: 256)
        let messages = try await ConversationContext().prepare(
            thread: thread, question: question, runID: XCTUnwrap(thread.pendingTurn?.id), store: store,
            provider: provider, baseRequest: base
        )
        let source = messages.compactMap { message -> String? in
            guard case .user(let parts) = message, case .text(let text) = parts.first,
                  text.hasPrefix("Selected original conversation turns") else { return nil }
            return text
        }.joined()
        XCTAssertTrue(source.contains("The Orchid project ships Thursday."))
        XCTAssertTrue(source.contains("Correction: the Orchid project ships Friday, not Thursday."))
        XCTAssertLessThan(try XCTUnwrap(source.range(of: "The Orchid")).lowerBound,
                          try XCTUnwrap(source.range(of: "Correction:")).lowerBound)
        var prepared = base
        prepared.messages = messages
        XCTAssertNoThrow(try prepared.reservingOutput(in: 4096))
        let saved = await store.thread(id: thread.id)
        XCTAssertEqual(saved?.turns, turns)
    }

    func testRecallRetainsFailedOutcomeAndMatchesAccentedNames() async throws {
        let (_, store) = try fixture()
        var export = PerryThread.Turn(question: "Export the Zéphyr report.", answer: "Exported.")
        export.outcome = .failed
        export.failureReason = "The export could not be verified."
        let original = try await store.upsert(PerryThread(turns: [export] + longThread().turns))
        let question = "Did the ZEPHYR export succeed?"
        let thread = try await store.beginTurn(to: original.id, question: question)
        let provider = ScriptedProvider(responses: Array(repeating: [.textDelta("The export succeeded."), .done(.endTurn)], count: 20), capacity: 4096)
        let base = ModelRequest(messages: [.user([.text(question)])], maxOutputTokens: 256)
        let messages = try await ConversationContext().prepare(
            thread: thread, question: question, runID: XCTUnwrap(thread.pendingTurn?.id), store: store,
            provider: provider, baseRequest: base
        )
        let source = messages.compactMap { message -> String? in
            guard case .user(let parts) = message, case .text(let text) = parts.first,
                  text.hasPrefix("Selected original conversation turns") else { return nil }
            return text
        }.joined()
        XCTAssertTrue(source.contains("Zéphyr"))
        XCTAssertTrue(source.contains("\"outcome\":\"failed\""))
        XCTAssertTrue(source.contains("The export could not be verified."))
        XCTAssertFalse(source.contains("Question 0:"))
        var prepared = base
        prepared.messages = messages
        XCTAssertNoThrow(try prepared.reservingOutput(in: 4096))
    }

    func testRecallCanSelectWhenEveryOlderTurnMatches() async throws {
        let (_, store) = try fixture()
        let turns = (0..<20).map { index in
            PerryThread.Turn(question: "Orchid update \(index)", answer: String(repeating: "A", count: 200))
        }
        let original = try await store.upsert(PerryThread(turns: turns))
        let question = "Orchid?"
        let thread = try await store.beginTurn(to: original.id, question: question)
        let provider = ScriptedProvider(responses: Array(repeating: [.textDelta("Updates exist."), .done(.endTurn)], count: 40), capacity: 4096)
        let base = ModelRequest(messages: [.user([.text(question)])], maxOutputTokens: 256)
        let messages = try await ConversationContext().prepare(
            thread: thread, question: question, runID: XCTUnwrap(thread.pendingTurn?.id), store: store,
            provider: provider, baseRequest: base
        )
        XCTAssertTrue(messages.contains { message in
            guard case .user(let parts) = message, case .text(let text) = parts.first else { return false }
            return text.hasPrefix("Selected original conversation turns") && text.contains("Orchid update")
        })
    }

    func testRetrievalDoesNotHideCorrectionDisplacedFromRecentHistory() async throws {
        let (_, store) = try fixture()
        var turns = [PerryThread.Turn(question: "Orchid ships Thursday.", answer: String(repeating: "a", count: 600))]
        turns += Array(repeating: longThread().turns[0], count: 18)
        turns.append(.init(question: "Orchid ships Friday instead.", answer: String(repeating: "b", count: 250)))
        turns += Array(repeating: longThread().turns[0], count: 3)
        let original = try await store.upsert(PerryThread(turns: turns))
        let question = "When does Orchid ship?"
        let thread = try await store.beginTurn(to: original.id, question: question)
        let provider = ScriptedProvider(responses: Array(repeating: [.textDelta("The garden is quiet."), .done(.endTurn)], count: 40), capacity: 4096)
        let base = ModelRequest(messages: [.user([.text(question)])], maxOutputTokens: 256)
        let messages = try await ConversationContext().prepare(
            thread: thread, question: question, runID: XCTUnwrap(thread.pendingTurn?.id), store: store,
            provider: provider, baseRequest: base
        )
        XCTAssertTrue(messages.contains { message in
            guard case .user(let parts) = message, case .text(let text) = parts.first else { return false }
            return text.contains("Orchid ships Friday instead.")
        })
        var prepared = base
        prepared.messages = messages
        XCTAssertNoThrow(try prepared.reservingOutput(in: 4096))
    }

    func testIncompleteSummaryDoesNotReplaceSavedContext() async throws {
        let (_, store) = try fixture()
        let original = longThread()
        _ = try await store.upsert(original)
        let thread = try await store.beginTurn(to: original.id, question: "Continue")
        let provider = ScriptedProvider(responses: [[.textDelta("Unfinished"), .done(.maxTokens)]])
        do {
            _ = try await ConversationContext().prepare(thread: thread, question: "Continue", runID: XCTUnwrap(thread.pendingTurn?.id), store: store, provider: provider, historyByteLimit: 2_048)
            XCTFail("Incomplete summaries must not be used")
        } catch ConversationContextError.incompleteSummary {}
        let saved = await store.thread(id: thread.id)
        XCTAssertNil(saved?.contextSummary)
        XCTAssertEqual(saved?.turns, thread.turns)
        XCTAssertEqual(saved?.pendingTurn, thread.pendingTurn)
    }

    func testSourceEditInvalidatesSummaryButAppendingDoesNot() async throws {
        let (_, store) = try fixture()
        let original = longThread()
        _ = try await store.upsert(original)
        let thread = try await store.beginTurn(to: original.id, question: "Continue")
        try await store.saveContextSummary("Cedar", sourceTurns: Array(thread.turns.prefix(4)), to: thread.id, runID: XCTUnwrap(thread.pendingTurn?.id))
        let saved = await store.thread(id: thread.id)
        var edited = try XCTUnwrap(saved)
        edited.turns.append(.init(question: "New", answer: "More"))
        let appended = try await store.upsert(edited)
        XCTAssertNotNil(appended.contextSummary)
        edited.turns[0] = .init(question: "Correction", answer: "Birch")
        let corrected = try await store.upsert(edited)
        XCTAssertNil(corrected.contextSummary)
        do {
            try await store.saveContextSummary("Stale Cedar", sourceTurns: Array(thread.turns.prefix(4)), to: thread.id, runID: XCTUnwrap(thread.pendingTurn?.id))
            XCTFail("A stale summary must not be saved")
        } catch ThreadStoreError.contextChanged {}
    }

    func testCancelledPreparationDoesNotCallProvider() async throws {
        let (_, store) = try fixture()
        let original = longThread()
        _ = try await store.upsert(original)
        let thread = try await store.beginTurn(to: original.id, question: "Continue")
        let provider = ScriptedProvider(responses: [])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ConversationContext().prepare(thread: thread, question: "Continue", runID: XCTUnwrap(thread.pendingTurn?.id), store: store, provider: provider, historyByteLimit: 2_048)
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        XCTAssertTrue(provider.requests.isEmpty)
    }

    func testSmallContextPreservesEveryUnicodeScalarWhileCondensing() async throws {
        let (_, store) = try fixture()
        let originalText = "a" + String(repeating: "\u{0301}", count: 2000) + String(repeating: "🪴", count: 2000) + "THE LAST FACT"
        let original = PerryThread(turns: [.init(question: "Remember everything", answer: originalText)])
        _ = try await store.upsert(original)
        let thread = try await store.beginTurn(to: original.id, question: "Continue")
        let provider = ScriptedProvider(responses: Array(repeating: [.textDelta("The last fact remains saved."), .done(.endTurn)], count: 30), capacity: 8192)
        let base = ModelRequest(system: String(repeating: "Instruction ", count: 100), messages: [.user([.text("Continue")])])
        let messages = try await ConversationContext().prepare(
            thread: thread, question: "Continue", runID: XCTUnwrap(thread.pendingTurn?.id), store: store,
            provider: provider, baseRequest: base
        )
        let fragments = provider.requests.flatMap(\.messages).compactMap { message -> String? in
            guard case .user(let parts) = message, case .text(let text) = parts.first else { return nil }
            return text.components(separatedBy: "\nNext transcript fragment:\n").last
        }.joined()
        XCTAssertTrue(fragments.contains(originalText))
        XCTAssertGreaterThan(provider.requests.count, 1)
        var prepared = base
        prepared.messages = messages
        XCTAssertNoThrow(try prepared.reservingOutput(in: 8192))
        let saved = await store.thread(id: thread.id)
        XCTAssertEqual(saved?.turns.first?.answer, originalText)
        XCTAssertEqual(saved?.contextSummary?.sourceTurnCount, 1)
    }

    func testOversizedTurnIsReadInBoundedFragments() async throws {
        let (_, store) = try fixture()
        let marker = "THE FINAL FACT IS CEDAR"
        let original = PerryThread(turns: [.init(question: "Read all", answer: String(repeating: "x", count: 8_000) + marker)])
        _ = try await store.upsert(original)
        let thread = try await store.beginTurn(to: original.id, question: "Which fact?")
        let provider = ScriptedProvider(responses: Array(repeating: [.textDelta("Cedar"), .done(.endTurn)], count: 20))
        _ = try await ConversationContext().prepare(thread: thread, question: "Which fact?", runID: XCTUnwrap(thread.pendingTurn?.id), store: store, provider: provider, historyByteLimit: 2_048)
        let inputs = provider.requests.flatMap(\.messages).compactMap { message -> String? in
            guard case .user(let parts) = message, case .text(let text) = parts.first else { return nil }
            return text
        }
        XCTAssertTrue(inputs.joined().contains(marker))
        XCTAssertTrue(inputs.allSatisfy { $0.count < 1_700 })
        let saved = await store.thread(id: thread.id)
        XCTAssertEqual(saved?.contextSummary?.sourceTurnCount, 1)
        XCTAssertEqual(saved?.turns.first?.answer, original.turns.first?.answer)
    }
}
