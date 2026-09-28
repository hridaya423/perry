import CoreGraphics
import Foundation
import Intents
import PerryBrain

/// Phase 9 morning suggestions: once per calendar day (after 6am), runs one
/// read-only researcher turn per *connected* integration, each proposing up
/// to `SuggestionRules.maxCards` cards as JSON. Cards are ranked with the
/// ignore-backoff rules — a morning that replaces un-acted cards raises
/// tomorrow's bar. Quiet when Focus is on or the screen is being shared.
@MainActor
final class SuggestionController {
    private let coordinator: AgentCoordinator
    private let backend: any IntegrationBackend
    /// A foreground Do run owns the user's attention — generation waits.
    private let isBusy: @MainActor () -> Bool
    var onSuggestionsChanged: (@MainActor ([SuggestionCard]) -> Void)?

    /// Fixed thread so research turns stay inspectable in Home.
    private let threadID = UUID(uuidString: "A6E11C7E-0000-4A00-9E00-000000000009")!
    private var timer: Timer?
    private(set) var cards: [SuggestionCard] = []

    private var defaults: UserDefaults { .standard }
    private var lastRunDayKey: String { "perry.suggestions.lastRunDay" }
    private var ignoredDaysKey: String { "perry.suggestions.ignoredDays" }
    private var pendingCardsKey: String { "perry.suggestions.pending" }

    init(
        coordinator: AgentCoordinator,
        backend: any IntegrationBackend,
        isBusy: @escaping @MainActor () -> Bool
    ) {
        self.coordinator = coordinator
        self.backend = backend
        self.isBusy = isBusy
    }

    func start() {
        guard timer == nil else { return }
        restorePending()
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.maybeGenerate() }
        }
        Task { await maybeGenerate() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Card actions

    /// "Do it" — the card becomes a goal on its own thread; the card leaves
    /// the pending set and the ignore streak resets.
    func act(on card: SuggestionCard, perform: (SuggestionCard) -> Void) {
        cards.removeAll { $0.id == card.id }
        persistPending()
        defaults.set(0, forKey: ignoredDaysKey)
        publish()
        perform(card)
    }

    func dismiss(_ card: SuggestionCard) {
        cards.removeAll { $0.id == card.id }
        persistPending()
        publish()
    }

    // MARK: - Generation

    private func maybeGenerate() async {
        let now = Date()
        let cal = Calendar.current
        guard cal.component(.hour, from: now) >= 6 else { return }
        let day = cal.startOfDay(for: now).timeIntervalSince1970
        guard defaults.double(forKey: lastRunDayKey) != day else { return }
        guard !quietNow(), !isBusy() else { return }
        defaults.set(day, forKey: lastRunDayKey)

        let connected = (try? await backend.services().filter { $0.connected }) ?? []
        guard !connected.isEmpty else { return }

        // Un-acted cards from the last run count as ignored → higher bar.
        if !cards.isEmpty {
            defaults.set(defaults.integer(forKey: ignoredDaysKey) + 1, forKey: ignoredDaysKey)
        }

        var fresh: [SuggestionCard] = []
        for service in connected {
            fresh += await research(service)
        }
        let minScore = SuggestionRules.effectiveMinScore(
            base: 0.3, ignoredDays: defaults.integer(forKey: ignoredDaysKey)
        )
        cards = SuggestionRules.rank(fresh, minScore: minScore)
        persistPending()
        publish()
    }

    /// One researcher turn per service: read-only ops only — the researcher
    /// has no write tools in scope because `integrations.write` is gated by
    /// tier and never requested by this prompt.
    private func research(_ service: IntegrationService) async -> [SuggestionCard] {
        let ops = service.operations.filter { !$0.isWrite }.map(\.name).joined(separator: ", ")
        guard !ops.isEmpty else { return [] }
        let prompt = """
        You are Perry's morning researcher for the connected service "\(service.name)" (id "\(service.id)").
        Read-only operations available via integrations.read: \(ops).
        Skim roughly the last 48 hours. Propose up to 3 suggestions that are genuinely worth
        the user's attention right now — not routine noise. Reply with ONLY a JSON array:
        [{"title": "…", "body": "one-sentence rationale + proposed action", "score": 0.0-1.0}]
        Empty array if nothing merits attention.
        """
        var text = ""
        for await event in coordinator.run(threadID: threadID, goal: prompt) {
            if case .textDelta(let delta) = event { text += delta }
        }
        return Self.parseCards(text, serviceID: nil)
    }

    /// First JSON array in the reply → cards, scored as given and validated.
    static func parseCards(_ text: String, serviceID: UUID?) -> [SuggestionCard] {
        guard let start = text.firstIndex(of: "["),
              let end = text[start...].lastIndex(of: "]") else { return [] }
        guard let rows = try? JSONDecoder().decode(
            [CardPayload].self, from: Data(text[start...end].utf8)
        ) else { return [] }
        return rows.compactMap { row in
            let title = row.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = row.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !body.isEmpty else { return nil }
            return SuggestionCard(
                title: title, body: body,
                sourcePerryID: serviceID,
                score: min(max(row.score, 0), 1)
            )
        }
    }

    private struct CardPayload: Decodable {
        let title: String
        let body: String
        let score: Double
    }

    // MARK: - Quiet hours

    /// Plan §4.6 quiet hours. Focus covers most call/share scenarios.
    /// ponytail: explicit call and screen-share detection (CoreAudio device
    /// polling, ScreenCaptureKit session state) is out of scope — upgrade
    /// path is a SCStream share-state observer.
    private func quietNow() -> Bool {
        INFocusStatusCenter.default.focusStatus.isFocused == true
    }

    // MARK: - Persistence

    private func persistPending() {
        let data = try? JSONEncoder().encode(cards)
        defaults.set(data, forKey: pendingCardsKey)
    }

    private func restorePending() {
        guard let data = defaults.data(forKey: pendingCardsKey),
              let restored = try? JSONDecoder().decode([SuggestionCard].self, from: data)
        else { return }
        cards = restored
        publish()
    }

    private func publish() {
        onSuggestionsChanged?(cards)
    }
}
