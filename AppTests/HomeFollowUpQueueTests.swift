import XCTest
import PerryBrain
@testable import Perry

@MainActor
final class HomeFollowUpQueueTests: XCTestCase {
    private var model: HomeModel!
    private var sent: [String] = []
    private var stopped: [UUID] = []
    private var accepting = true
    private var staged: [PerryThread.WaitingInput] = []
    private var removed: [UUID] = []
    private var sentIDs: [UUID?] = []
    private let thread = UUID()

    override func setUp() async throws {
        model = HomeModel()
        sent = []
        stopped = []
        accepting = true
        staged = []
        removed = []
        sentIDs = []
        model.threads = [PerryThread(id: thread)]
        model.onQueueFollowUp = { [unowned self] _, input in staged.append(input) }
        model.onRemoveWaitingInput = { [unowned self] _, id in removed.append(id) }
        model.onSend = { [unowned self] _, text, id in
            guard accepting else { return false }
            sent.append(text)
            sentIDs.append(id)
            model.pendingQuestions[thread] = .init(text: text, turnIndex: 0)
            return true
        }
        model.onStop = { [unowned self] in stopped.append($0) }
    }

    private func finish(_ outcome: AgentFinish) {
        model.turnEnded(threadID: thread, finish: outcome)
        model.pendingQuestions[thread] = nil
    }

    func testIdleSendGoesStraightThrough() {
        model.send(threadID: thread, text: "first ")
        XCTAssertEqual(sent, ["first "])
        XCTAssertNil(model.queuedFollowUps[thread])
    }

    func testFollowUpWhileWorkingWaitsAndSendsWhenTheTurnCompletes() {
        model.send(threadID: thread, text: "first")
        model.draftChanged(threadID: thread, draft: "second")
        model.send(threadID: thread, text: "second")
        XCTAssertEqual(sent, ["first"])
        XCTAssertEqual(model.queuedFollowUps[thread]?.map(\.text), ["second"])
        XCTAssertEqual(model.drafts[thread], "")
        finish(.completed)
        XCTAssertEqual(sent, ["first", "second"])
        XCTAssertNil(model.queuedFollowUps[thread])
    }

    func testReturnOnTheMessageAlreadyBeingAnsweredClearsItWithoutQueueingACopy() {
        model.draftChanged(threadID: thread, draft: "first")
        model.send(threadID: thread, text: "first")
        model.send(threadID: thread, text: " first ")
        XCTAssertEqual(sent, ["first"])
        XCTAssertNil(model.queuedFollowUps[thread])
        XCTAssertEqual(model.drafts[thread], "")
    }

    func testQueueWaitsForTheWorkerToFinishToo() {
        model.send(threadID: thread, text: "first")
        model.workingThreads = [thread]
        model.send(threadID: thread, text: "second")
        finish(.completed)
        XCTAssertEqual(sent, ["first"])
        model.workingThreads = []
        XCTAssertEqual(sent, ["first", "second"])
    }

    func testQueuedMessagesGoOneAtATimeInOrder() {
        model.send(threadID: thread, text: "first")
        model.send(threadID: thread, text: "second")
        model.send(threadID: thread, text: "third")
        finish(.completed)
        XCTAssertEqual(sent, ["first", "second"])
        finish(.completed)
        XCTAssertEqual(sent, ["first", "second", "third"])
    }

    func testStopPausesTheQueueUntilTheUserSendsIt() throws {
        model.send(threadID: thread, text: "first")
        model.send(threadID: thread, text: "second")
        model.stop(threadID: thread)
        XCTAssertEqual(stopped, [thread])
        finish(.interrupted)
        XCTAssertEqual(sent, ["first"])
        XCTAssertTrue(model.pausedQueues.contains(thread))
        let queued = try XCTUnwrap(model.queuedFollowUps[thread]?.first)
        model.sendQueuedNow(threadID: thread, id: queued.id)
        XCTAssertEqual(sent, ["first", "second"])
        XCTAssertFalse(model.pausedQueues.contains(thread))
    }

    func testAFailedTurnPausesTheQueue() {
        model.send(threadID: thread, text: "first")
        model.send(threadID: thread, text: "second")
        finish(.failed("no network"))
        XCTAssertEqual(sent, ["first"])
        XCTAssertTrue(model.pausedQueues.contains(thread))
    }

    func testSendNowStopsTheCurrentTurnAndSendsWhenItEnds() throws {
        model.send(threadID: thread, text: "first")
        model.send(threadID: thread, text: "second")
        model.send(threadID: thread, text: "third")
        let third = try XCTUnwrap(model.queuedFollowUps[thread]?.last)
        model.sendQueuedNow(threadID: thread, id: third.id)
        XCTAssertEqual(stopped, [thread])
        finish(.interrupted)
        XCTAssertEqual(sent, ["first", "third"])
        XCTAssertEqual(model.queuedFollowUps[thread]?.map(\.text), ["second"])
    }

    func testRemovingTheLastQueuedMessageClearsThePause() throws {
        model.send(threadID: thread, text: "first")
        model.send(threadID: thread, text: "second")
        model.stop(threadID: thread)
        finish(.interrupted)
        let queued = try XCTUnwrap(model.queuedFollowUps[thread]?.first)
        model.removeQueued(threadID: thread, id: queued.id)
        XCTAssertNil(model.queuedFollowUps[thread])
        XCTAssertFalse(model.pausedQueues.contains(thread))
    }

    func testANewMessageAfterAStopIsSentRatherThanQueuedBehindThePause() {
        model.send(threadID: thread, text: "first")
        model.send(threadID: thread, text: "second")
        model.stop(threadID: thread)
        finish(.interrupted)
        model.send(threadID: thread, text: "different")
        XCTAssertEqual(sent, ["first", "different"])
        XCTAssertEqual(model.queuedFollowUps[thread]?.map(\.text), ["second"])
    }

    func testARejectedSendKeepsTheMessageQueued() {
        model.send(threadID: thread, text: "first")
        model.send(threadID: thread, text: "second")
        accepting = false
        finish(.completed)
        XCTAssertEqual(sent, ["first"])
        XCTAssertEqual(model.queuedFollowUps[thread]?.map(\.text), ["second"])
        accepting = true
        model.sendQueuedFollowUps()
        XCTAssertEqual(sent, ["first", "second"])
        XCTAssertNil(model.queuedFollowUps[thread])
    }

    func testQueuedWorkIsDroppedWhenTheThreadNoLongerExists() {
        model.send(threadID: thread, text: "first")
        model.send(threadID: thread, text: "second")
        model.threads = []
        finish(.completed)
        XCTAssertEqual(sent, ["first"])
        XCTAssertNil(model.queuedFollowUps[thread])
    }

    func testQueueDrainsWhenThePendingTurnClearsFromTheThreadList() {
        var busy = PerryThread(id: thread)
        busy.pendingTurn = .init(id: UUID(), question: "first", startedAt: Date())
        model.threads = [busy]
        model.send(threadID: thread, text: "first")
        model.send(threadID: thread, text: "second")
        finish(.completed)
        XCTAssertEqual(sent, ["first"])
        model.threads = [PerryThread(id: thread)]
        XCTAssertEqual(sent, ["first", "second"])
    }

    func testSendNowDoesNotLeaveALingeringFlagWhenTheStopNeverEndsATurn() throws {
        model.send(threadID: thread, text: "first")
        model.send(threadID: thread, text: "second")
        model.send(threadID: thread, text: "third")
        let third = try XCTUnwrap(model.queuedFollowUps[thread]?.last)
        model.sendQueuedNow(threadID: thread, id: third.id)
        model.pendingQuestions[thread] = nil
        XCTAssertEqual(sent, ["first", "third"])
        finish(.interrupted)
        XCTAssertTrue(model.pausedQueues.contains(thread))
        XCTAssertEqual(sent, ["first", "third"])
    }

    func testAnInterruptedThreadDoesNotReceiveQueuedWork() {
        var thread = PerryThread(id: self.thread)
        thread.pendingTurn = .init(id: UUID(), question: "first", startedAt: Date())
        model.threads = [thread]
        model.pendingQuestions[self.thread] = .init(text: "first", turnIndex: 0)
        model.send(threadID: self.thread, text: "second")
        model.pendingQuestions[self.thread] = nil
        XCTAssertEqual(sent, [])
    }

    func testQueuingStagesTheTrimmedTextWithTheQueuedRowsID() throws {
        model.send(threadID: thread, text: "first")
        model.send(threadID: thread, text: "  second  ")
        model.send(threadID: thread, text: "third")
        let queued = try XCTUnwrap(model.queuedFollowUps[thread])
        XCTAssertEqual(staged.map(\.id), queued.map(\.id))
        XCTAssertEqual(staged.map(\.text), ["second", "third"])
    }

    func testIdleSendAndTheInFlightDuplicateStageNothing() {
        model.send(threadID: thread, text: "first")
        model.send(threadID: thread, text: "first")
        XCTAssertTrue(staged.isEmpty)
        XCTAssertEqual(sentIDs, [nil])
    }

    func testDrainingSendsTheQueuedRowsID() throws {
        model.send(threadID: thread, text: "first")
        model.send(threadID: thread, text: "second")
        let queued = try XCTUnwrap(model.queuedFollowUps[thread]?.first)
        finish(.completed)
        XCTAssertEqual(sentIDs, [nil, queued.id])
    }

    func testSendNowSendsThatRowsID() throws {
        model.send(threadID: thread, text: "first")
        model.send(threadID: thread, text: "second")
        model.send(threadID: thread, text: "third")
        let third = try XCTUnwrap(model.queuedFollowUps[thread]?.last)
        model.sendQueuedNow(threadID: thread, id: third.id)
        finish(.interrupted)
        XCTAssertEqual(sentIDs.last, third.id)
        XCTAssertTrue(removed.isEmpty)
    }

    func testRemovingAQueuedRowRemovesItsStagedInputOnce() throws {
        model.send(threadID: thread, text: "first")
        model.send(threadID: thread, text: "second")
        let queued = try XCTUnwrap(model.queuedFollowUps[thread]?.first)
        model.removeQueued(threadID: thread, id: queued.id)
        model.removeQueued(threadID: thread, id: queued.id)
        XCTAssertEqual(removed, [queued.id])
    }

    func testQueueButtonsNameTheMessageTheyAffect() {
        XCTAssertEqual(QueuedFollowUpsView.actionLabel("Send now", for: "Add the totals"), "Send now: Add the totals")
        XCTAssertEqual(
            QueuedFollowUpsView.actionLabel("Remove", for: "Please summarise the last three meetings for Priya"),
            "Remove: Please summarise the last three meetings…"
        )
        XCTAssertEqual(
            QueuedFollowUpsView.actionLabel("Remove", for: String(repeating: "x", count: 100)),
            "Remove: " + String(repeating: "x", count: 60) + "…"
        )
    }
}
