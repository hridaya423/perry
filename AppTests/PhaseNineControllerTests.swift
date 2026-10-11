import XCTest
import PerryBrain
import PerryCore
@testable import Perry

@MainActor
final class PerrySchedulerControllerTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-scheduler-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeScheduler(
        provider: PhaseNineProvider, busy: Bool = false
    ) -> (PerrySchedulerController, PerryStore) {
        let store = PerryStore(directory: directory.appendingPathComponent("perrys"))
        let coordinator = AgentCoordinator(
            provider: { _ in provider },
            host: PerryToolHost(executors: []),
            threads: ThreadStore(directory: directory.appendingPathComponent("threads")),
            consent: ToolConsentStore(directory: nil)
        )
        return (PerrySchedulerController(store: store, coordinator: coordinator, isBusy: { busy }), store)
    }

    func testTickRunsDuePerryOnItsThreadAndRecordsSuccess() async throws {
        let provider = PhaseNineProvider()
        let (scheduler, store) = makeScheduler(provider: provider)
        scheduler.start()
        defer { scheduler.stop() }
        await scheduler.joinAll()

        let perry = try await store.create(job: "tidy the fixture", schedule: RoutineSchedule(kind: .interval(1)))
        await scheduler.tick(now: Date(), awake: true, network: true)
        await scheduler.joinAll()

        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertEqual(provider.requests.first?.lastUserText, "tidy the fixture")

        let updated = await store.list().first { $0.id == perry.id }
        XCTAssertNotNil(updated?.schedule?.lastRun)
        XCTAssertEqual(updated?.schedule?.consecutiveFailures, 0)
        XCTAssertFalse(updated?.schedule?.paused ?? true)
    }

    func testTickSkipsWhenAsleepOfflineOrBusy() async throws {
        let provider = PhaseNineProvider()
        let (scheduler, store) = makeScheduler(provider: provider)
        scheduler.start()
        defer { scheduler.stop() }
        await scheduler.joinAll()
        _ = try await store.create(job: "never runs", schedule: RoutineSchedule(kind: .interval(1)))

        await scheduler.tick(now: Date(), awake: false, network: true)
        await scheduler.tick(now: Date(), awake: true, network: false)
        await scheduler.joinAll()
        XCTAssertTrue(provider.requests.isEmpty)
    }

    func testTickSkipsWhileForegroundRunIsBusy() async throws {
        let provider = PhaseNineProvider()
        let (scheduler, store) = makeScheduler(provider: provider, busy: true)
        scheduler.start()
        defer { scheduler.stop() }
        await scheduler.joinAll()
        _ = try await store.create(job: "never runs", schedule: RoutineSchedule(kind: .interval(1)))

        await scheduler.tick(now: Date(), awake: true, network: true)
        await scheduler.joinAll()
        XCTAssertTrue(provider.requests.isEmpty)
    }

    func testFailedRunIncrementsConsecutiveFailures() async throws {
        let provider = PhaseNineProvider(throwing: true)
        let (scheduler, store) = makeScheduler(provider: provider)
        scheduler.start()
        defer { scheduler.stop() }
        await scheduler.joinAll()

        let perry = try await store.create(job: "fails", schedule: RoutineSchedule(kind: .interval(1)))
        await scheduler.tick(now: Date(), awake: true, network: true)
        await scheduler.joinAll()

        let updated = await store.list().first { $0.id == perry.id }
        XCTAssertEqual(updated?.schedule?.consecutiveFailures, 1)
        XCTAssertFalse(updated?.schedule?.paused ?? true)
    }
}

@MainActor
final class SuggestionControllerTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perry-suggestions-\(UUID().uuidString)", isDirectory: true)
        suiteName = "perry.suggestions.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    private var nineAM: Date {
        Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    }

    private func makeController(
        provider: PhaseNineProvider,
        services: [IntegrationService] = [StubBackend.connectedService],
        busy: Bool = false
    ) -> SuggestionController {
        let coordinator = AgentCoordinator(
            provider: { _ in provider },
            host: PerryToolHost(executors: []),
            threads: ThreadStore(directory: directory.appendingPathComponent("threads")),
            consent: ToolConsentStore(directory: nil)
        )
        return SuggestionController(
            coordinator: coordinator, backend: StubBackend(listedServices: services),
            isBusy: { busy }, defaults: defaults
        )
    }

    func testGeneratesRankedCardsFromConnectedServices() async throws {
        let provider = PhaseNineProvider(text: """
        [{"title": "Replied late to Nadia", "body": "Her email sat 3 days — draft a reply.", "score": 0.8}]
        """)
        let controller = makeController(provider: provider)
        defaults.set(true, forKey: PerryPreferences.$suggestionsEnabled.key)
        var published: [[SuggestionCard]] = []
        controller.onSuggestionsChanged = { published.append($0) }

        controller.start(at: nineAM)
        defer { controller.stop() }
        await controller.joinAll()

        XCTAssertEqual(provider.requests.count, 1)
        // Only read operations are advertised to the researcher.
        let prompt = provider.requests[0].lastUserText ?? ""
        XCTAssertTrue(prompt.contains("recent.mail"))
        XCTAssertFalse(prompt.contains("send.mail"))

        XCTAssertEqual(controller.cards.count, 1)
        XCTAssertEqual(controller.cards.first?.title, "Replied late to Nadia")
        XCTAssertEqual(controller.cards.first?.sourceServiceID, StubBackend.connectedService.id)
        XCTAssertTrue(published.contains { !$0.isEmpty })

        // Persisted across launches.
        let reloaded = makeController(provider: provider, services: [])
        reloaded.reloadCards()
        XCTAssertEqual(reloaded.cards.count, 1)
    }

    func testSameDaySecondRunDoesNotRegenerate() async throws {
        let provider = PhaseNineProvider()
        let controller = makeController(provider: provider)
        defaults.set(true, forKey: PerryPreferences.$suggestionsEnabled.key)
        controller.start(at: nineAM)
        defer { controller.stop() }
        await controller.joinAll()
        XCTAssertEqual(provider.requests.count, 1)

        controller.requestGeneration(at: nineAM.addingTimeInterval(3600))
        await controller.joinAll()
        XCTAssertEqual(provider.requests.count, 1)
    }

    func testGatesSuppressGeneration() async throws {
        // Disabled flag.
        var provider = PhaseNineProvider()
        var controller = makeController(provider: provider)
        controller.start(at: nineAM)
        await controller.joinAll()
        controller.stop()
        XCTAssertTrue(provider.requests.isEmpty)

        // Before 6am.
        provider = PhaseNineProvider()
        controller = makeController(provider: provider)
        defaults.set(true, forKey: PerryPreferences.$suggestionsEnabled.key)
        let threeAM = Calendar.current.date(bySettingHour: 3, minute: 0, second: 0, of: Date()) ?? Date()
        controller.start(at: threeAM)
        await controller.joinAll()
        controller.stop()
        XCTAssertTrue(provider.requests.isEmpty)

        // Nothing connected.
        provider = PhaseNineProvider()
        controller = makeController(provider: provider, services: [])
        controller.start(at: nineAM)
        await controller.joinAll()
        controller.stop()
        XCTAssertTrue(provider.requests.isEmpty)
    }

    func testIgnoreStreakRaisesTheScoreBar() async throws {
        // Two ignored days → minScore = 0.3 + 0.15*2 = 0.6; a 0.5 card drops.
        defaults.set(true, forKey: PerryPreferences.$suggestionsEnabled.key)
        defaults.set(2, forKey: PerryPreferences.$suggestionsIgnoredDays.key)
        let provider = PhaseNineProvider(text: """
        [{"title": "Weak", "body": "below the bar", "score": 0.5},
         {"title": "Strong", "body": "above the bar", "score": 0.9}]
        """)
        let controller = makeController(provider: provider)
        controller.start(at: nineAM)
        defer { controller.stop() }
        await controller.joinAll()

        XCTAssertEqual(controller.cards.map(\.title), ["Strong"])
    }

    func testActClearsPendingAndResetsIgnoreStreak() {
        let controller = makeController(provider: PhaseNineProvider(), services: [])
        defaults.set(3, forKey: PerryPreferences.$suggestionsIgnoredDays.key)
        let card = SuggestionCard(title: "t", body: "b", score: 0.9)
        controller.dismiss(card) // sanity: dismissing unknown id is a no-op
        var acted: SuggestionCard?
        controller.act(on: card) { acted = $0 }
        XCTAssertEqual(acted, card)
        XCTAssertEqual(defaults.integer(forKey: PerryPreferences.$suggestionsIgnoredDays.key), 0)
    }

    func testParseCardsFiltersMalformedRows() {
        let cards = SuggestionController.parseCards(
            "noise [{\"title\":\"\",\"body\":\"x\",\"score\":0.5},"
                + "{\"title\":\"ok\",\"body\":\"b\",\"score\":1.7}] tail",
            serviceID: nil
        )
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?.score, 1.0)
        XCTAssertEqual(SuggestionController.parseCards("no json", serviceID: nil), [])
    }
}

// MARK: - Fixtures

private extension ModelRequest {
    var lastUserText: String? {
        for message in messages.reversed() {
            guard case .user(let parts) = message else { continue }
            let text = parts.compactMap { part -> String? in
                if case .text(let value) = part { return value }
                return nil
            }.joined()
            if !text.isEmpty { return text }
        }
        return nil
    }
}

/// Records requests and plays back a scripted stream — either fixed text
/// plus `.done`, or a throwing stream for failure paths.
private final class PhaseNineProvider: ModelProvider, @unchecked Sendable {
    let id: ProviderID = "fixture.phase-nine"
    let displayName = "Fixture"
    let capabilities: ModelCapabilities = [.streaming, .tools, .vision]
    private let text: String
    private let throwing: Bool
    private let lock = NSLock()
    private var recorded: [ModelRequest] = []
    var requests: [ModelRequest] { lock.withLock { recorded } }

    init(text: String = "Done.", throwing: Bool = false) {
        self.text = text
        self.throwing = throwing
    }

    func warm() async {}
    func contextWindow(for tier: ModelTier) async throws -> Int? { nil }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        lock.withLock { recorded.append(request) }
        let text = self.text
        let throwing = self.throwing
        return AsyncThrowingStream { continuation in
            let task = Task {
                if throwing {
                    continuation.yield(.textDelta("partial"))
                    continuation.finish(throwing: URLError(.timedOut))
                    return
                }
                continuation.yield(.textDelta(text))
                continuation.yield(.done(.endTurn))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private struct StubBackend: IntegrationBackend {
    let listedServices: [IntegrationService]

    func services() async throws -> [IntegrationService] { listedServices }

    static let connectedService = IntegrationService(
        id: "mail", name: "Mail", connected: true, writeEnabled: false,
        operations: [
            IntegrationOperation(name: "recent.mail", description: "list recent mail", isWrite: false),
            IntegrationOperation(name: "send.mail", description: "send mail", isWrite: true),
        ]
    )

    func perform(service: String, operation: String, arguments: JSONValue) async throws -> JSONValue {
        .null
    }
}
