import Foundation
import PerryBrain
import PerryGuide

@MainActor
final class ConversationLearner {
    private let complete: (String) async throws -> String
    private let threads: ThreadStore
    private let memory: MemoryStore
    private let remembered: (UUID, [MemoryRecord]) -> Void
    private let titled: () -> Void

    init(complete: @escaping (String) async throws -> String, threads: ThreadStore, memory: MemoryStore,
         remembered: @escaping (UUID, [MemoryRecord]) -> Void, titled: @escaping () -> Void) {
        self.complete = complete
        self.threads = threads
        self.memory = memory
        self.remembered = remembered
        self.titled = titled
    }

    func turnCompleted(threadID: UUID, question: String, answer: String) {
        Task {
            await title(threadID: threadID, question: question, answer: answer)
            await learn(threadID: threadID, question: question, answer: answer)
        }
    }

    private func title(threadID: UUID, question: String, answer: String) async {
        guard let thread = await threads.thread(id: threadID), thread.turns.count == 1,
              thread.title == ThreadStore.derivedTitle(from: question),
              let reply = try? await complete(Self.titlePrompt(question: question, answer: answer)),
              let title = Self.cleanTitle(reply) else { return }
        try? await threads.setTitle(title, for: threadID)
        titled()
    }

    private func learn(threadID: UUID, question: String, answer: String) async {
        let configuration = await memory.currentConfiguration()
        guard configuration.enabled, configuration.categoryToggles[.aboutYou] == true else { return }
        let known = await memory.snapshot().filter { $0.category == .aboutYou }.map(\.summary)
        guard let reply = try? await complete(MemoryExtraction.prompt(question: question, answer: answer, known: known)) else { return }
        var saved: [MemoryRecord] = []
        for fact in MemoryExtraction.decode(reply, known: known) {
            let record = MemoryRecord(
                category: .aboutYou, summary: fact.text, subject: fact.subject,
                expiresAt: fact.days.map { Date().addingTimeInterval(Double($0) * 86_400) }
            )
            if await memory.remember(record) { saved.append(record) }
        }
        if !saved.isEmpty { remembered(threadID, saved) }
    }

    static func titlePrompt(question: String, answer: String) -> String {
        """
        Write a title of two to five words for this conversation. Use plain words, sentence case, no quotes, no final period.
        Reply with the title only.

        User: \(question.prefix(600))
        Assistant: \(answer.prefix(600))
        """
    }

    static func cleanTitle(_ reply: String) -> String? {
        let line = reply.components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        var title = line.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\"“”'*#.")))
        if title.lowercased().hasPrefix("title:") { title = String(title.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        let words = title.split(whereSeparator: \.isWhitespace)
        guard (1...7).contains(words.count), title.count <= 48 else { return nil }
        return title
    }
}
