import XCTest
@testable import PerryBrain

final class PerryStoreTests: XCTestCase {
    private var dir: URL!
    private var store: PerryStore!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = PerryStore(directory: dir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    func testCreateListUpdateRemove() async throws {
        let perry = try await store.create(job: "clean my desktop every morning")
        XCTAssertEqual(perry.name, "Tidy Desk")
        var fetched = await store.list()
        XCTAssertEqual(fetched.map(\.id), [perry.id])

        var updated = perry
        updated.job = "different job"
        try await store.update(updated)
        fetched = await store.list()
        XCTAssertEqual(fetched.first?.job, "different job")

        try await store.remove(id: perry.id)
        let remaining = await store.list()
        XCTAssertEqual(remaining.count, 0)
    }

    func testPerryMemoryFile() async throws {
        let perry = try await store.create(job: "watch the build")
        let empty = await store.memory(for: perry.id)
        XCTAssertEqual(empty, "")
        try await store.setMemory("prefers short pings", for: perry.id)
        let stored = await store.memory(for: perry.id)
        XCTAssertEqual(stored, "prefers short pings")
        let other = try await store.create(job: "sort downloads")
        let otherMemory = await store.memory(for: other.id)
        XCTAssertEqual(otherMemory, "")
        try await store.remove(id: perry.id)
        let afterRemove = await store.memory(for: perry.id)
        XCTAssertEqual(afterRemove, "")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("\(perry.id.uuidString).memory.md").path
        ))
    }

    func testCorruptFileSkipped() async throws {
        _ = try await store.create(job: "read the news every morning")
        try "not json".write(to: dir.appendingPathComponent("broken.json"), atomically: true, encoding: .utf8)
        let list = await store.list()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.name, "Morning Scout") // "read"+"news" → scout
    }

    func testNameGeneratorDeterministic() {
        XCTAssertEqual(PerryNameGenerator.twoWordName(for: "clean my desktop"), "Tidy Desk")
        XCTAssertEqual(PerryNameGenerator.twoWordName(for: "clean my desktop"), "Tidy Desk")
        XCTAssertEqual(PerryNameGenerator.twoWordName(for: "read my inbox"), "Inbox Keeper")
        XCTAssertFalse(PerryNameGenerator.twoWordName(for: "xyzzy").isEmpty)
        XCTAssertEqual(PerryNameGenerator.twoWordName(for: "xyzzy"), PerryNameGenerator.twoWordName(for: "xyzzy"))
    }
}

final class RoutineDecisionsTests: XCTestCase {
    private let cal = Calendar.current
    private func day(_ h: Int, _ m: Int = 0, offset: Int = 0) -> Date {
        var c = cal.dateComponents([.year, .month, .day], from: Date())
        c.hour = h; c.minute = m; c.second = 0
        return cal.date(byAdding: .day, value: offset, to: cal.date(from: c)!)!
    }

    func testDailyFiresAtSlot() {
        let s = RoutineSchedule(kind: .daily(hour: 9, minute: 0))
        XCTAssertTrue(RoutineDecisions.shouldRun(s, now: day(9, 30), isAwake: true, hasNetwork: true))
        XCTAssertFalse(RoutineDecisions.shouldRun(s, now: day(8, 0), isAwake: true, hasNetwork: true))
    }

    func testNoRunWhenAsleepOrOffline() {
        let s = RoutineSchedule(kind: .daily(hour: 9, minute: 0))
        XCTAssertFalse(RoutineDecisions.shouldRun(s, now: day(10), isAwake: false, hasNetwork: true))
        XCTAssertFalse(RoutineDecisions.shouldRun(s, now: day(10), isAwake: true, hasNetwork: false))
    }

    func testMissedSlotCatchesUpOnce() {
        var s = RoutineSchedule(kind: .daily(hour: 9, minute: 0))
        s = RoutineDecisions.recordMissed(s, now: day(10))
        XCTAssertTrue(s.missedRunPending)
        XCTAssertTrue(RoutineDecisions.shouldRun(s, now: day(11), isAwake: true, hasNetwork: true))
        s = RoutineDecisions.record(s, succeeded: true, ranAt: day(11))
        XCTAssertFalse(s.missedRunPending)
        XCTAssertFalse(RoutineDecisions.shouldRun(s, now: day(11), isAwake: true, hasNetwork: true))
    }

    func testThreeFailuresPause() {
        var s = RoutineSchedule(kind: .interval(60))
        for _ in 0..<2 {
            s = RoutineDecisions.record(s, succeeded: false, ranAt: Date())
        }
        XCTAssertFalse(s.paused)
        s = RoutineDecisions.record(s, succeeded: false, ranAt: Date())
        XCTAssertTrue(s.paused)
        XCTAssertNil(RoutineDecisions.nextFire(s, now: Date()))
    }

    func testSuccessResetsFailures() {
        var s = RoutineSchedule(kind: .interval(60))
        s = RoutineDecisions.record(s, succeeded: false, ranAt: Date())
        s = RoutineDecisions.record(s, succeeded: true, ranAt: Date())
        XCTAssertEqual(s.consecutiveFailures, 0)
    }

    func testOnceRunsOnce() {
        let s = RoutineSchedule(kind: .once(Date().addingTimeInterval(-60)))
        XCTAssertTrue(RoutineDecisions.shouldRun(s, now: Date(), isAwake: true, hasNetwork: true))
        let ran = RoutineDecisions.record(s, succeeded: true, ranAt: Date())
        XCTAssertFalse(RoutineDecisions.shouldRun(ran, now: Date(), isAwake: true, hasNetwork: true))
    }

    func testIntervalDrift() {
        var s = RoutineSchedule(kind: .interval(3600))
        XCTAssertTrue(RoutineDecisions.shouldRun(s, now: Date(), isAwake: true, hasNetwork: true))
        s = RoutineDecisions.record(s, succeeded: true, ranAt: Date())
        XCTAssertFalse(RoutineDecisions.shouldRun(s, now: Date(), isAwake: true, hasNetwork: true))
        XCTAssertTrue(RoutineDecisions.shouldRun(
            s, now: Date().addingTimeInterval(3700), isAwake: true, hasNetwork: true
        ))
    }
}

final class SuggestionRulesTests: XCTestCase {
    private func card(_ title: String, _ score: Double) -> SuggestionCard {
        SuggestionCard(title: title, body: "", score: score)
    }

    func testQuietNow() {
        XCTAssertTrue(SuggestionRules.quietNow(isOnCall: true, isScreenSharing: false, focusActive: false))
        XCTAssertTrue(SuggestionRules.quietNow(isOnCall: false, isScreenSharing: true, focusActive: false))
        XCTAssertTrue(SuggestionRules.quietNow(isOnCall: false, isScreenSharing: false, focusActive: true))
        XCTAssertFalse(SuggestionRules.quietNow(isOnCall: false, isScreenSharing: false, focusActive: false))
    }

    func testRankTrimsToThreeSorted() {
        let ranked = SuggestionRules.rank([
            card("a", 0.5), card("b", 0.9), card("c", 0.4), card("d", 0.8), card("e", 0.1),
        ])
        XCTAssertEqual(ranked.map(\.title), ["b", "d", "a"])
    }

    func testBackoffRaisesBar() {
        XCTAssertEqual(SuggestionRules.effectiveMinScore(base: 0.3, ignoredDays: 0), 0.3)
        XCTAssertEqual(SuggestionRules.effectiveMinScore(base: 0.3, ignoredDays: 2), 0.6)
        XCTAssertEqual(SuggestionRules.effectiveMinScore(base: 0.3, ignoredDays: 100), 0.9)
    }
}

final class MemoryFilesTests: XCTestCase {
    private var dir: URL!
    private var files: MemoryFiles!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        files = MemoryFiles(directory: dir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    func testRoundTrip() throws {
        XCTAssertEqual(files.profile(), "")
        try files.writeProfile("prefers terse answers")
        try files.writeContext("working on Perry")
        XCTAssertEqual(files.profile(), "prefers terse answers")
        XCTAssertEqual(files.context(), "working on Perry")
    }

    func testPromptBlockOmitsEmpty() throws {
        XCTAssertEqual(files.promptBlock(), "")
        try files.writeContext("ctx only")
        XCTAssertEqual(files.promptBlock(), "Current context:\nctx only")
        try files.writeProfile("prof")
        XCTAssertTrue(files.promptBlock().contains("Profile:\nprof"))
        XCTAssertTrue(files.promptBlock().contains("Current context:\nctx only"))
    }

    func testProfileFieldsUpsertOneLineEach() throws {
        XCTAssertNil(files.profileField("Name"))
        try files.writeProfile("prefers terse answers")
        try files.setProfileField("Name", "Ada")
        XCTAssertEqual(files.profile(), "prefers terse answers\n- Name: Ada\n")
        try files.setProfileField("Name", "  Ada Lovelace ")
        try files.setProfileField("Work", "Designer")
        XCTAssertEqual(files.profile(), "prefers terse answers\n- Name: Ada Lovelace\n- Work: Designer\n")
        XCTAssertEqual(files.profileField("name"), "Ada Lovelace")
        try files.setProfileField("Name", "")
        XCTAssertNil(files.profileField("Name"))
        XCTAssertEqual(files.profile(), "prefers terse answers\n- Work: Designer\n")
    }

    func testAtomicWriteLeavesNoTmp() throws {
        try files.writeProfile("x")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(".") || $0.hasSuffix(".tmp") }
        XCTAssertTrue(leftovers.isEmpty)
    }
}
