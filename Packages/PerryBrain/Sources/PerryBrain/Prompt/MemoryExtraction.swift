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

public enum InterviewPolicy {
    public static let maximumFollowUps = 2
    public static let timeBudget: TimeInterval = 90

    public static func isShort(_ answer: String?) -> Bool {
        (answer?.split(whereSeparator: \.isWhitespace).count ?? 0) <= 2
    }

    public static func shouldDig(answer: String?, followUpsAsked: Int, elapsed: TimeInterval) -> Bool {
        guard let answer, followUpsAsked < maximumFollowUps, elapsed < timeBudget else { return false }
        return answer.split(whereSeparator: \.isWhitespace).count >= 6
    }

    public static func shouldBackOff(shortStreak: Int, elapsed: TimeInterval) -> Bool {
        shortStreak >= 2 || elapsed >= timeBudget
    }

    public static func followUpPrompt(question: String, answer: String) -> String {
        """
        You are getting to know a new user. You asked: "\(question)" They said: "\(answer)"
        If their answer mentions something specific worth one short follow-up, write that question in at most 12 words, friendly and plain.
        Never ask about health, money, family or anything private. If nothing is worth asking, reply NONE.
        Reply with the question or NONE only.
        """
    }

    public static func cleanFollowUp(_ reply: String) -> String? {
        let line = reply.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”")))
        guard !line.isEmpty, !line.uppercased().hasPrefix("NONE"), line.hasSuffix("?"),
              line.split(whereSeparator: \.isWhitespace).count <= 16, !line.contains("\n") else { return nil }
        return line
    }
}

extension MemoryExtraction {
    public static let importRequest = "I’m moving to a new assistant. List everything you remember about me: my name, work, projects, the people I mention, the tools I use, my preferences and how I like answers written. Use one short plain fact per line, with no commentary."

    public static func importPrompt(_ notes: String) -> String {
        """
        The user pasted what another assistant remembers about them. Turn it into short facts in third person, at most 12 facts.
        Keep work, projects, people, tools, preferences and interests. Skip secrets, health and money details, and anything about the other assistant.
        Reply with JSON only: {"facts": [{"text": "short fact", "kind": "profile|preference|person|project|event", "subject": "one or two words", "days": null}]}

        Notes:
        \(notes.prefix(8_000))
        """
    }

    public static func decodeImport(_ text: String) -> [LearnedFact] {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              let reply = try? JSONDecoder().decode(ImportReply.self, from: Data(text[start...end].utf8)) else { return [] }
        var seen = Set<String>()
        return reply.facts.compactMap { fact in
            var fact = fact
            fact.text = fact.text.trimmingCharacters(in: .whitespacesAndNewlines)
            fact.subject = fact.subject.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !fact.text.isEmpty, fact.text.count <= 160, !looksSecret(fact.text), seen.insert(fact.text.lowercased()).inserted else { return nil }
            return fact
        }
        .prefix(12)
        .map { $0 }
    }

    private struct ImportReply: Decodable {
        let facts: [LearnedFact]
    }
}
