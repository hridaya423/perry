import Foundation

public struct ProfileFacts: Codable, Equatable, Sendable {
    public var work: String?
    public var apps: [String]
    public var learningGoal: String?

    public init(work: String?, apps: [String], learningGoal: String?) {
        self.work = work
        self.apps = apps
        self.learningGoal = learningGoal
    }
}

public enum ProfileExtraction {
    public static let questions = [
        "What’s your work?",
        "Which apps do you use most?",
        "What do you want to learn next?",
    ]

    public static let schema = #"{"work": string or null, "apps": [string], "learningGoal": string or null}"#

    public static func prompt(answers: [String?]) -> String {
        let pairs = zip(questions, answers).map { question, answer in
            "Q: \(question)\nA: \(answer?.isEmpty == false ? answer! : "(skipped)")"
        }
        return """
        Turn these interview answers into short profile facts. Use the person's own words, at most six words per fact. \
        Start each fact with a capital letter and write app names the way their makers do, such as GitHub or Figma. \
        Leave a fact null or empty when its answer was skipped or says nothing. Do not guess.
        Reply with JSON only, exactly this shape: \(schema)

        \(pairs.joined(separator: "\n\n"))
        """
    }

    public static func decode(_ text: String) throws -> ProfileFacts {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "No JSON object in the reply."))
        }
        var facts = try JSONDecoder().decode(ProfileFacts.self, from: Data(text[start...end].utf8))
        facts.work = facts.work.flatMap(clean)
        facts.learningGoal = facts.learningGoal.flatMap(clean)
        facts.apps = facts.apps.compactMap(clean)
        return facts
    }

    public static func reactionPrompt(question: String, answer: String) -> String {
        """
        You asked: "\(question)" They answered: "\(answer)"
        Acknowledge one thing they said in a plain sentence of at most 8 words. Start with a capital letter, end with a period and write app names the way their makers do. Do not add facts. No question, no emoji, no exclamation mark.
        Reply with the reaction only.
        """
    }

    public static func trimReaction(_ text: String) -> String? {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”")))
        let words = line.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty, words.count <= 10 else { return nil }
        return line
    }

    private static func clean(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
