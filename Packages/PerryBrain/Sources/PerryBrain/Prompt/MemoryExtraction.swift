import Foundation

public struct LearnedFact: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case profile, preference, person, project, event
    }

    public var text: String
    public var kind: Kind
    public var subject: String
    public var days: Int?

    public init(text: String, kind: Kind, subject: String, days: Int? = nil) {
        self.text = text
        self.kind = kind
        self.subject = subject
        self.days = days
    }
}

public enum MemoryExtraction {
    public static let maximumFactsPerTurn = 3

    public static func prompt(question: String, answer: String, known: [String]) -> String {
        """
        You keep a short memory about the user of a Mac assistant. Read one exchange and list only new, lasting facts about the user.
        Keep: their name, role, projects, people they work with, tools they rely on, preferences about how to answer, dates that matter.
        Skip: anything about the assistant, one-off requests, general knowledge, secrets such as passwords or keys, health or money details, and facts already known.
        Mark project and event facts with how many days they stay true.
        Reply with JSON only: {"facts": [{"text": "short fact in third person", "kind": "profile|preference|person|project|event", "subject": "one or two words naming what it is about", "days": number or null}]}
        Reply {"facts": []} when nothing new is worth keeping, which is most of the time.

        Already known:
        \(known.isEmpty ? "(nothing)" : known.map { "- \($0)" }.joined(separator: "\n"))

        User: \(question.prefix(2_000))
        Assistant: \(answer.prefix(2_000))
        """
    }

    public static func decode(_ text: String, known: [String]) -> [LearnedFact] {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              let reply = try? JSONDecoder().decode(Reply.self, from: Data(text[start...end].utf8)) else { return [] }
        let knownLower = Set(known.map { $0.lowercased() })
        var seen = Set<String>()
        return reply.facts.compactMap { fact -> LearnedFact? in
            var fact = fact
            fact.text = fact.text.trimmingCharacters(in: .whitespacesAndNewlines)
            fact.subject = fact.subject.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !fact.text.isEmpty, fact.text.count <= 160, !fact.subject.isEmpty,
                  !knownLower.contains(fact.text.lowercased()), !looksSecret(fact.text),
                  seen.insert(fact.text.lowercased()).inserted else { return nil }
            if let days = fact.days { fact.days = min(max(days, 1), 365) }
            return fact
        }
        .prefix(maximumFactsPerTurn)
        .map { $0 }
    }

    public static func looksSecret(_ text: String) -> Bool {
        let lower = text.lowercased()
        if ["password", "passcode", "api key", "secret", "pin code", "social security"].contains(where: lower.contains) { return true }
        if text.contains(#/\b(?:sk|pk|rk)[-_][A-Za-z0-9_\-]{12,}/#) { return true }
        if text.contains(#/\b(?:\d[ -]?){13,19}\b/#) { return true }
        return false
    }

    private struct Reply: Decodable {
        let facts: [LearnedFact]
    }
}
