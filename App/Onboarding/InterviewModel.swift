import AppKit
import PerryBrain
import PerryCore
import PerryGuide
import SwiftUI

@MainActor
final class InterviewModel: ObservableObject {
    enum Step: Equatable {
        case pronounce, question(Int), importOffer, importConsent(MemoryService), importing(MemoryService), summary, done
    }

    enum MemoryService: String, CaseIterable {
        case chatGPT = "ChatGPT"
        case claude = "Claude"

        static func heard(_ text: String) -> MemoryService? {
            let lowered = text.lowercased()
            if lowered.contains("claude") || lowered.contains("cloud") { return .claude }
            if lowered.contains("gpt") || lowered.contains("chat") { return .chatGPT }
            return nil
        }
    }

    enum Kind: Equatable {
        case intro, work, apps, goal, followUp
    }

    struct Facts: Equatable {
        var name = ""
        var work = ""
        var apps = ""
        var goal = ""
        var spoken = ""
        var style = ""
    }

    struct Note: Equatable, Identifiable {
        let id = UUID()
        var fact: LearnedFact
        var kept = true
    }

    struct Effects {
        var complete: ((String) async throws -> String)?
        var save: (Facts) -> Void = { _ in }
        var saveNotes: ([LearnedFact]) -> Void = { _ in }
        var sayName: (String) -> Void = { _ in }
        var say: (String) async -> Void = { _ in }
        var listensAfterSpeaking = true
        var importMemory: ((MemoryService) async -> String?)?
        var now: () -> Date = Date.init
    }

    static let knownApps = ["Notion", "Figma", "Xcode", "Slack", "Linear", "Visual Studio Code", "Cursor", "Safari", "Google Chrome", "Arc", "Mail", "Microsoft Word", "Keynote"]
    static let workChips = ["Student", "Designer", "Developer", "Founder"]

    static func appChips(installed: (String) -> Bool = { FileManager.default.fileExists(atPath: "/Applications/\($0).app") }) -> [String] {
        Array(knownApps.filter(installed).prefix(5))
    }

    static func cloudLine(choice: BrainController.ModelChoice, hasSavedChoice: Bool) -> String? {
        guard hasSavedChoice else { return nil }
        let service: String? = switch choice {
        case .chatGPT: "ChatGPT"
        case .claudeCode: "Claude Code"
        case .acp: "your coding agent"
        case .direct: "the service behind your API key"
        case .local: nil
        }
        return service.map { "I share your notes with \($0) when I answer." }
    }

    @Published private(set) var step: Step
    @Published private(set) var reaction: String?
    @Published private(set) var extracting = false
    @Published private(set) var thinking = false
    @Published var draft = ""
    @Published var facts: Facts
    @Published var notes: [Note] = []
    @Published private(set) var importFailed = false

    private(set) var questions = [ProfileExtraction.intro]
    private var kinds: [Kind] = [.intro]
    private var answers: [String?] = [nil]
    private var startedAt: Date?
    private var shortStreak = 0
    private let effects: Effects
    private var importTask: Task<Void, Never>?

    init(name: String, effects: Effects) {
        self.facts = Facts(name: name)
        self.effects = effects
        self.step = name.isEmpty ? .question(0) : .pronounce
        self.startedAt = effects.now()
    }

    var questionCount: Int { questions.count }
    var canImport: Bool { effects.complete != nil && effects.importMemory != nil }

    static func heardYes(_ text: String) -> Bool? {
        let words = Set(text.lowercased().split { !$0.isLetter }.map(String.init))
        if !words.isDisjoint(with: ["no", "nope", "not", "wrong", "actually", "but"]) { return false }
        if !words.isDisjoint(with: ["yes", "yeah", "yep", "yup", "right", "correct", "sure", "perfect", "exactly", "ok", "okay"]) { return true }
        return nil
    }

    func chooseImport(_ service: MemoryService?) {
        guard step == .importOffer else { return }
        guard let service, effects.importMemory != nil, effects.complete != nil else { return summarize() }
        step = .importConsent(service)
    }

    func allowImport(_ allowed: Bool) {
        guard case .importConsent(let service) = step else { return }
        guard allowed, let importMemory = effects.importMemory, let complete = effects.complete else { return summarize() }
        step = .importing(service)
        importTask = Task {
            let text = await importMemory(service)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !Task.isCancelled, step == .importing(service) else { return }
            if let text, !text.isEmpty, let reply = try? await complete(MemoryExtraction.importPrompt(text)) {
                guard !Task.isCancelled, step == .importing(service) else { return }
                let known = Set(notes.map { $0.fact.text.lowercased() })
                notes += MemoryExtraction.decodeImport(reply).filter { !known.contains($0.text.lowercased()) }.map { Note(fact: $0) }
            }
            importFailed = notes.isEmpty
            summarize()
        }
    }

    func cancelImport() {
        switch step {
        case .importConsent, .importing: break
        default: return
        }
        importTask?.cancel()
        importTask = nil
        summarize()
    }

    func suspendImport() {
        guard case .importing(let service) = step else { return }
        importTask?.cancel()
        importTask = nil
        step = .importConsent(service)
    }

    var summaryLines: [String] {
        [("Work", facts.work), ("Apps", facts.apps), ("First thing to learn", facts.goal)]
            .filter { !$0.1.isEmpty }
            .map { "\($0.0): \($0.1)." } + notes.map(\.fact.text)
    }

    var spokenSummary: String {
        let known = [("Work", facts.work), ("Apps", facts.apps), ("First thing to learn", facts.goal)].filter { !$0.1.isEmpty }
        let lines = known.map { "\($0.0): \($0.1)." }
        let imported = notes.isEmpty ? [] : ["And \(notes.count) \(notes.count == 1 ? "thing" : "things") from your other assistant."]
        let failed = importFailed ? ["I couldn’t read your other assistant. You can paste its notes later in Settings, under You."] : []
        return (failed + ["Here’s what I have."] + lines + imported + ["Did I get that right?"]).joined(separator: " ")
    }

    func confirmSummary() {
        guard step == .summary else { return }
        effects.save(facts)
        effects.saveNotes(notes.filter(\.kept).map(\.fact))
        step = .done
    }

    func correct(_ text: String) {
        guard step == .summary, !thinking else { return }
        let correction = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !correction.isEmpty, let complete = effects.complete else { return confirmSummary() }
        let understood = summaryLines.prefix(3).joined(separator: " ")
        thinking = true
        Task {
            defer { thinking = false }
            let reply = try? await withTimeout(seconds: 20) {
                try await complete(ProfileExtraction.prompt(answers: [("I understood: \(understood) Did I get that right?", correction)]))
            }
            if let fixed = reply.flatMap({ try? ProfileExtraction.decode($0) }) {
                if let work = fixed.work { facts.work = Self.capitalized(work) }
                if !fixed.apps.isEmpty { facts.apps = fixed.apps.map(Self.capitalized).joined(separator: ", ") }
                if let goal = fixed.learningGoal { facts.goal = Self.capitalized(goal) }
            }
            confirmSummary()
        }
    }

    var spokenName: String { facts.spoken.isEmpty ? facts.name : facts.spoken }

    func spokenPrompt(at index: Int) -> String {
        kinds[index] == .intro ? "\(ProfileExtraction.intro) \(ProfileExtraction.introHint)" : questions[index]
    }

    var listensAfterSpeaking: Bool { effects.listensAfterSpeaking }

    func say(_ line: String) async {
        await effects.say(line)
    }

    func sayName(spelled: String? = nil) {
        effects.sayName(spelled ?? (facts.spoken.isEmpty ? facts.name : facts.spoken))
    }

    func confirmPronunciation() {
        guard step == .pronounce else { return }
        facts.spoken = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        step = .question(0)
    }

    func answer(_ text: String?) {
        guard case .question(let index) = step, !thinking else { return }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let answer = trimmed.isEmpty ? nil : trimmed
        answers[index] = answer
        draft = ""
        reaction = nil
        if kinds[index] == .intro { return introduce(answer, at: index) }
        shortStreak = InterviewPolicy.isShort(answer) ? shortStreak + 1 : 0
        let elapsed = startedAt.map { effects.now().timeIntervalSince($0) } ?? 0
        let followUps = kinds.filter { $0 == .followUp }.count
        if InterviewPolicy.shouldBackOff(shortStreak: shortStreak, elapsed: elapsed) || index + 1 >= questions.count {
            return finishQuestions()
        }
        guard let complete = effects.complete, let answer else { return step = .question(index + 1) }
        if kinds[index] != .followUp, InterviewPolicy.shouldDig(answer: answer, followUpsAsked: followUps, elapsed: elapsed) {
            thinking = true
            let question = questions[index]
            Task {
                let reply = try? await withTimeout(seconds: 4) { try await complete(InterviewPolicy.followUpPrompt(question: question, answer: answer)) }
                thinking = false
                guard step == .question(index) else { return }
                if let followUp = reply.flatMap(InterviewPolicy.cleanFollowUp) {
                    questions.insert(followUp, at: index + 1)
                    kinds.insert(.followUp, at: index + 1)
                    answers.insert(nil, at: index + 1)
                }
                step = .question(index + 1)
            }
            return
        }
        step = .question(index + 1)
        let next = step
        Task {
            let text = try? await complete(ProfileExtraction.reactionPrompt(question: questions[index], answer: answer))
            guard step == next else { return }
            reaction = text.flatMap(ProfileExtraction.trimReaction)
        }
    }

    func kind(at index: Int) -> Kind { kinds[index] }

    private func introduce(_ answer: String?, at index: Int) {
        guard let answer else { return finishQuestions() }
        guard let complete = effects.complete else { return finishQuestions() }
        thinking = true
        Task {
            async let profile = try? withTimeout(seconds: 20) {
                try await complete(ProfileExtraction.prompt(answers: [(ProfileExtraction.intro, answer)]))
            }
            async let followUp = try? withTimeout(seconds: 20) {
                try await complete(InterviewPolicy.followUpPrompt(question: ProfileExtraction.intro, answer: answer))
            }
            let extracted = await profile.flatMap { try? ProfileExtraction.decode($0) }
            let question = await followUp.flatMap(InterviewPolicy.cleanFollowUp)
            thinking = false
            guard step == .question(index) else { return }
            guard let extracted else { return finishQuestions() }
            facts.work = extracted.work.map(Self.capitalized) ?? ""
            facts.apps = extracted.apps.map(Self.capitalized).joined(separator: ", ")
            facts.goal = extracted.learningGoal.map(Self.capitalized) ?? ""
            let missing = missingFacts()
            ask(missing.isEmpty ? question.map { [($0, .followUp)] } ?? [] : missing, after: index)
        }
    }

    private func missingFacts() -> [(String, Kind)] {
        zip(ProfileExtraction.questions, [Kind.work, .apps, .goal]).filter { _, kind in
            switch kind {
            case .work: facts.work.isEmpty
            case .apps: facts.apps.isEmpty
            default: facts.goal.isEmpty
            }
        }
    }

    private func ask(_ next: [(String, Kind)], after index: Int) {
        guard !next.isEmpty else { return finishQuestions() }
        questions += next.map(\.0)
        kinds += next.map(\.1)
        answers += next.map { _ in nil }
        step = .question(index + 1)
    }

    func cancel() {
        importTask?.cancel()
        importTask = nil
        step = .done
    }

    static func capitalized(_ text: String?) -> String {
        guard let text, let first = text.first else { return text ?? "" }
        let word = text.prefix { !$0.isWhitespace }
        guard word.allSatisfy({ !$0.isUppercase }) else { return text }
        return first.uppercased() + text.dropFirst()
    }

    private func finishQuestions() {
        for (kind, answer) in zip(kinds, answers) {
            guard let answer else { continue }
            switch kind {
            case .work: facts.work = Self.capitalized(answer)
            case .apps: facts.apps = Self.capitalized(answer)
            case .goal: facts.goal = Self.capitalized(answer)
            case .intro, .followUp: break
            }
        }
        extract()
        if canImport { step = .importOffer } else { summarize() }
    }

    private func summarize() {
        let knowsSomething = !facts.work.isEmpty || !facts.apps.isEmpty || !facts.goal.isEmpty || !notes.isEmpty
        if knowsSomething {
            step = .summary
        } else {
            if !facts.spoken.isEmpty { effects.save(facts) }
            step = .done
        }
    }

    private func extract() {
        guard let complete = effects.complete else { return }
        let typed = facts
        let asked = zip(zip(questions, answers), kinds)
        let core = asked.filter { $0.1 != .followUp }.map { (question: $0.0.0, answer: $0.0.1) }
        let followUps = asked.filter { $0.1 == .followUp || $0.1 == .intro }.compactMap { pair in
            pair.0.1.map { "Q: \(pair.0.0)\nA: \($0)" }
        }
        extracting = true
        Task {
            defer { extracting = false }
            if let text = try? await complete(ProfileExtraction.prompt(answers: core)),
               let extracted = try? ProfileExtraction.decode(text), step != .done, facts == typed {
                facts.work = extracted.work.map(Self.capitalized) ?? typed.work
                facts.apps = extracted.apps.isEmpty ? typed.apps : extracted.apps.map(Self.capitalized).joined(separator: ", ")
                facts.goal = extracted.learningGoal.map(Self.capitalized) ?? typed.goal
            }
            guard !followUps.isEmpty, let reply = try? await complete(MemoryExtraction.importPrompt(followUps.joined(separator: "\n\n"))) else { return }
            let known = Set(notes.map { $0.fact.text.lowercased() })
            notes += MemoryExtraction.decodeImport(reply).filter { !known.contains($0.text.lowercased()) }.map { Note(fact: $0) }
        }
    }
}

private func withTimeout<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw CancellationError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
