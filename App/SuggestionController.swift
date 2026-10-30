import CoreGraphics
import Foundation
import PerryBrain

@MainActor
final class SuggestionController {
    private let coordinator: AgentCoordinator
    private let backend: any IntegrationBackend
    private let isBusy: @MainActor () -> Bool
    var onSuggestionsChanged: (@MainActor ([SuggestionCard]) -> Void)?

    private let threadID = UUID(uuidString: "A6E11C7E-0000-4A00-9E00-000000000009")!
    private var timer: Timer?
    private var generationTask: Task<Void, Never>?
    private var defaultsObserver: NSObjectProtocol?
    private(set) var cards: [SuggestionCard] = []

    private let defaults: UserDefaults

    init(
        coordinator: AgentCoordinator,
        backend: any IntegrationBackend,
        isBusy: @escaping @MainActor () -> Bool,
        defaults: UserDefaults = .standard
    ) {
        self.coordinator = coordinator
        self.backend = backend
        self.isBusy = isBusy
        self.defaults = defaults
    }

    func start(at now: Date = Date()) {
        guard timer == nil else { return }
        reloadCards()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.defaults.bool(forKey: PerryPreferences.$suggestionsEnabled.key) else { return }
                self.coordinator.stop(threadID: self.threadID)
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.requestGeneration() }
        }
        requestGeneration(at: now)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = nil
        generationTask?.cancel()
        coordinator.stop(threadID: threadID)
    }

    func joinAll() async {
        await generationTask?.value
    }

    func requestGeneration(at now: Date = Date()) {
        guard timer != nil, generationTask == nil else { return }
        generationTask = Task {
            defer { generationTask = nil }
            await maybeGenerate(at: now)
        }
    }

    func act(on card: SuggestionCard, perform: (SuggestionCard) -> Void) {
        cards.removeAll { $0.id == card.id }
        persistPending()
        defaults.set(0, forKey: PerryPreferences.$suggestionsIgnoredDays.key)
        publish()
        perform(card)
    }

    func adjust(_ card: SuggestionCard) {
        guard let index = cards.firstIndex(where: { $0.id == card.id }) else { return }
        cards[index].body = card.body
        persistPending()
        publish()
    }

    func dismiss(_ card: SuggestionCard) {
        cards.removeAll { $0.id == card.id }
        persistPending()
        publish()
    }

    private func maybeGenerate(at now: Date) async {
        guard !Task.isCancelled, defaults.bool(forKey: PerryPreferences.$suggestionsEnabled.key) else { return }
        let cal = Calendar.current
        guard cal.component(.hour, from: now) >= 6 else { return }
        let day = cal.startOfDay(for: now).timeIntervalSince1970
        guard defaults.double(forKey: PerryPreferences.$suggestionsLastRunDay.key) != day else { return }
        guard !QuietHours.isActive, !isBusy() else { return }
        defaults.set(day, forKey: PerryPreferences.$suggestionsLastRunDay.key)

        let connected = (try? await backend.services().filter { $0.connected }) ?? []
        guard !Task.isCancelled, !connected.isEmpty else { return }

        if !cards.isEmpty {
            let ignoredDays = defaults.integer(forKey: PerryPreferences.$suggestionsIgnoredDays.key)
            defaults.set(ignoredDays + 1, forKey: PerryPreferences.$suggestionsIgnoredDays.key)
        }

        var fresh: [SuggestionCard] = []
        for service in connected {
            guard !Task.isCancelled, defaults.bool(forKey: PerryPreferences.$suggestionsEnabled.key) else { return }
            fresh += await research(service)
        }
        guard !Task.isCancelled else { return }
        let minScore = SuggestionRules.effectiveMinScore(
            base: 0.3, ignoredDays: defaults.integer(forKey: PerryPreferences.$suggestionsIgnoredDays.key)
        )
        cards = SuggestionRules.rank(fresh, minScore: minScore)
        persistPending()
        publish()
    }

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
        let result = await coordinator.runToEnd(threadID: threadID, goal: prompt, kind: .suggestion)
        return Self.parseCards(result.answer, serviceID: nil).map { card in
            var card = card
            card.sourceServiceID = service.id
            card.sourceServiceName = service.name
            return card
        }
    }

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

    private func persistPending() {
        let data = try? JSONEncoder().encode(cards)
        defaults.set(data, forKey: PerryPreferences.$suggestionsPending.key)
    }

    func reloadCards() {
        cards = defaults.data(forKey: PerryPreferences.$suggestionsPending.key).flatMap { try? JSONDecoder().decode([SuggestionCard].self, from: $0) } ?? []
        publish()
    }

    private func publish() {
        onSuggestionsChanged?(cards)
    }
}
