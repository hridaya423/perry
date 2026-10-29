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
        /// Speaks a line and returns once it has been said, so the mic can open after it.
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
        Task {
            let text = await importMemory(service)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let text, !text.isEmpty, let reply = try? await complete(MemoryExtraction.importPrompt(text)) {
                let known = Set(notes.map { $0.fact.text.lowercased() })
                notes += MemoryExtraction.decodeImport(reply).filter { !known.contains($0.text.lowercased()) }.map { Note(fact: $0) }
            }
            guard step == .importing(service) else { return }
            importFailed = notes.isEmpty
            summarize()
        }
    }

    func cancelImport() {
        switch step {
        case .importConsent, .importing: break
        default: return
        }
        summarize()
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

extension AppController {
    func saveInterview(_ facts: InterviewModel.Facts) async {
        guard let files = memoryFiles else { return }
        for (field, value) in [("Name", facts.name), ("Work", facts.work), ("Apps", facts.apps), ("Learning goal", facts.goal), ("Answer style", facts.style)] {
            try? files.setProfileField(field, value)
        }
        if !facts.name.isEmpty, !facts.spoken.isEmpty {
            try? PronunciationStore(directory: storageDirectory).set(Pronunciation(written: facts.name, spoken: facts.spoken))
        }
        await setMemoryEnabled(true)
    }

    func importMemory(from service: InterviewModel.MemoryService) async -> String? {
        let page = URL(string: service == .chatGPT ? "https://chatgpt.com/#settings/Personalization" : "https://claude.ai/settings/capabilities")!
        let browser = NSWorkspace.shared.urlForApplication(toOpen: page)
        let bundleID = browser.flatMap { Bundle(url: $0)?.bundleIdentifier }
        let browserName = browser?.deletingPathExtension().lastPathComponent ?? "the browser"
        let goal = switch service {
        case .chatGPT: """
            ChatGPT’s settings are open in \(browserName), on Personalization. Open the memory summary, or Manage memories. \
            It opens in a dialog over the settings. ChatGPT can take up to a minute to write the summary, so look again every few \
            seconds until the text appears. Read the text inside the dialog, not the page behind it, and scroll inside the dialog \
            to its end if it is long. Give all of it back word for word as your answer, with nothing added. Do not change or delete anything. \
            If the page asks me to sign in or log in, answer exactly SIGNED_OUT.
            """
        case .claude: """
            Claude’s settings are open in \(browserName), on Capabilities. Find Memory and open what Claude remembers about me. \
            It may open in a dialog: read the text inside the dialog, not the page behind it, and scroll inside it to the end. \
            Wait until it has loaded, then give all of it back word for word as your answer, with nothing added. \
            Do not change or delete anything. If the page asks me to sign in or log in, answer exactly SIGNED_OUT.
            """
        }
        for attempt in 0..<3 {
            if attempt > 0 {
                voice.speak("Sign in to \(service.rawValue), and I’ll try again.")
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return nil }
            }
            NSWorkspace.shared.open(page)
            try? await Task.sleep(for: .seconds(3))
            let target = bundleID.map { CuaTargetHint(bundleID: $0) }
            var answer = ""
            for await event in agentCoordinator.run(threadID: UUID(), goal: goal, target: target, task: true) {
                if case .textDelta(let delta) = event { answer += delta }
            }
            let reply = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            if reply.contains("SIGNED_OUT") { continue }
            return reply.isEmpty ? nil : reply
        }
        return nil
    }

    func saveImportedFacts(_ facts: [LearnedFact]) async {
        guard !facts.isEmpty else { return }
        await setMemoryEnabled(true)
        for fact in facts {
            _ = await memoryStore.remember(MemoryRecord(category: .aboutYou, summary: fact.text, subject: fact.subject))
        }
    }
}

@MainActor
final class InterviewListener: ObservableObject {
    @Published private(set) var listening = false
    private var input: DictationController?
    private var detector: EndOfTurnDetector?

    func start(onPartial: @escaping (String) -> Void, onDone: @escaping (String) -> Void) {
        guard !listening else { return }
        Task {
            guard await DictationController.ensurePermission() else { return }
            let input = DictationController(
                onTranscript: { [weak self] text in
                    Task { @MainActor in
                        self?.stop()
                        onDone(text)
                    }
                },
                onPartial: { [weak self] text in
                    Task { @MainActor in
                        guard let self, self.listening else { return }
                        onPartial(text)
                        _ = self.detector?.transcript(at: ProcessInfo.processInfo.systemUptime, text: text, lastWordEnd: 0)
                    }
                },
                onLevel: { [weak self] time, rms in
                    Task { @MainActor in self?.level(rms, at: time) }
                },
                onFailure: { [weak self] _ in
                    Task { @MainActor in self?.stop() }
                }
            )
            do {
                try input.start()
            } catch {
                return
            }
            self.input = input
            detector = EndOfTurnDetector(startedAt: ProcessInfo.processInfo.systemUptime)
            listening = true
        }
    }

    func finish() {
        guard listening else { return }
        listening = false
        input?.finish()
    }

    func stop() {
        listening = false
        input?.cancel()
        input = nil
        detector = nil
    }

    private func level(_ rms: Double, at time: TimeInterval) {
        guard listening else { return }
        switch detector?.frame(at: time, rms: rms) {
        case .commit?: finish()
        case .abort?: stop()
        default: break
        }
    }
}

struct InterviewBeat: View {
    @ObservedObject var director: OnboardingDirector
    @StateObject var model: InterviewModel
    let cloudLine: String?
    let appChips: [String]
    @StateObject private var listener = InterviewListener()
    @State private var typing = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            switch model.step {
            case .pronounce: pronounce
            case .question(let index): question(index)
            case .importOffer: importOffer
            case .importConsent(let service): importConsent(service)
            case .importing(let service): importing(service)
            case .summary: summary
            case .done: Color.clear
            }
        }
        .onChange(of: model.step) { previous, step in
            listener.stop()
            if previous == .pronounce { typing = false }
            if step == .done { director.skip() }
        }
        .onDisappear { listener.stop() }
    }

    private static let installedAssistants = ["chatgpt", "claude"].filter { id in
        BrandCatalog.entries[id]?.bundleIDs.contains { AppIcons.installed(bundleID: $0) != nil } == true
    }

    private var pronounce: some View {
        OnboardingBeatLayout(title: "Did I say \(model.facts.name) right?", message: typing ? "Type it the way it sounds." : nil) {
            EmptyView()
        } detail: {
            HStack(spacing: 8) {
                Button { model.sayName(spelled: typing && !model.draft.isEmpty ? model.draft : nil) } label: {
                    Image(systemName: "speaker.wave.2.fill")
                        .frame(width: PerryTheme.Icon.hit, height: PerryTheme.Icon.hit)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .foregroundStyle(PerryTheme.Colors.accent)
                .accessibilityLabel("Hear Perry say your name")
                if typing {
                    TextField("For example, Hrid-yah", text: $model.draft)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.leading)
                        .font(PerryTheme.Scale.input)
                        .focused($focused)
                        .focusEffectDisabled()
                        .onSubmit { model.confirmPronunciation() }
                        .task { focused = true }
                }
            }
            .padding(.horizontal, 10)
            .frame(width: typing ? 360 : nil, height: 44)
            .background(typing ? PerryTheme.Colors.surface : .clear, in: RoundedRectangle(cornerRadius: PerryTheme.Radius.panel, style: .continuous))
            .task {
                await model.say("Hi \(model.spokenName). Did I say your name right?")
                guard model.listensAfterSpeaking, !typing, !Task.isCancelled else { return }
                listener.start(onPartial: { _ in }, onDone: { text in
                    if InterviewModel.heardYes(text) == false {
                        typing = true
                    } else {
                        model.draft = ""
                        model.confirmPronunciation()
                    }
                })
            }
        } actions: {
            OnboardingFooter {
                EmptyView()
            } primary: {
                Button {
                    if !typing { model.draft = "" }
                    model.confirmPronunciation()
                } label: { OnboardingPrimaryLabel(title: typing ? "Save" : "Yes") }
                    .buttonStyle(InkButtonStyle())
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(typing && model.draft.trimmingCharacters(in: .whitespaces).isEmpty)
            } trailing: {
                if !typing {
                    Button("Not quite") { typing = true }
                }
            }
        }
    }

    private func question(_ index: Int) -> some View {
        OnboardingBeatLayout(title: model.questions[index], message: model.reaction ?? (model.kind(at: index) == .intro ? ProfileExtraction.introHint : nil)) {
            EmptyView()
        } detail: {
            VStack(spacing: 12) {
                if typing {
                    answerField(index)
                } else {
                    spokenAnswer
                }
                chips(index)
                if model.kind(at: index) == .intro {
                    Text(cloudLine ?? "I keep notes on this Mac. You can delete them any time.")
                        .font(PerryTheme.Scale.secondary)
                        .foregroundStyle(PerryTheme.Colors.textTertiary)
                }
            }
        } actions: {
            OnboardingFooter {
                OnboardingProgress(current: index, count: model.questionCount)
                    .padding(.trailing, 10)
            } primary: {
                if !listener.listening, typing || model.thinking || !model.draft.isEmpty {
                    Button { model.answer(model.draft) } label: { OnboardingPrimaryLabel(title: model.thinking ? "Thinking…" : "Continue") }
                        .buttonStyle(InkButtonStyle())
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.thinking || model.draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } trailing: {
                HStack(spacing: 14) {
                    if !typing {
                        Button("Type") {
                            listener.stop()
                            typing = true
                        }
                    }
                    Button("Skip") { model.answer(nil) }
                }
                .disabled(model.thinking)
            }
        }
        .id(index)
        .task(id: index) {
            model.draft = ""
            await model.say(model.spokenPrompt(at: index))
            guard !typing, model.listensAfterSpeaking, !Task.isCancelled else { return }
            listen()
        }
    }

    private func listen() {
        listener.start(onPartial: { model.draft = $0 }, onDone: { text in
            model.draft = text
            if !text.trimmingCharacters(in: .whitespaces).isEmpty { model.answer(text) }
        })
    }

    private var spokenAnswer: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                if listener.listening { listener.finish() } else { listen() }
            } label: {
                Image(systemName: listener.listening ? "waveform" : "mic.fill")
                    .symbolEffect(.variableColor.iterative, isActive: listener.listening)
                    .font(PerryTheme.Icon.utility)
                    .foregroundStyle(listener.listening ? PerryTheme.Colors.accent : PerryTheme.Colors.icon)
                    .frame(width: PerryTheme.Icon.hit, height: PerryTheme.Icon.hit)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(listener.listening ? "Stop listening" : "Answer by voice")
            Text(model.draft.isEmpty ? (listener.listening ? "Listening…" : model.thinking ? "Thinking…" : "Tap the mic to answer.") : model.draft)
                .font(PerryTheme.Scale.input)
                .foregroundStyle(model.draft.isEmpty ? PerryTheme.Colors.textTertiary : PerryTheme.Colors.text)
                .multilineTextAlignment(.leading)
                .lineLimit(5)
                .frame(maxWidth: model.draft.isEmpty ? nil : .infinity, alignment: .leading)
                .padding(.top, 6)
        }
        .frame(width: model.draft.isEmpty ? nil : 360)
        .frame(minHeight: 44)
    }

    private func answerField(_ index: Int) -> some View {
        HStack(spacing: 8) {
            TextField(listener.listening ? "Listening…" : "Type or tap the mic", text: $model.draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.leading)
                .font(PerryTheme.Scale.input)
                .focused($focused)
                .focusEffectDisabled()
                .onSubmit { if !model.draft.trimmingCharacters(in: .whitespaces).isEmpty { model.answer(model.draft) } }
            Button {
                if listener.listening {
                    listener.finish()
                } else {
                    listener.start(onPartial: { model.draft = $0 }, onDone: { model.draft = $0 })
                }
            } label: {
                Image(systemName: listener.listening ? "waveform" : "mic")
                    .font(PerryTheme.Icon.utility)
                    .foregroundStyle(listener.listening ? PerryTheme.Colors.accent : PerryTheme.Colors.icon)
                    .frame(width: PerryTheme.Icon.hit, height: PerryTheme.Icon.hit)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(listener.listening ? "Stop listening" : "Answer by voice")
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .frame(width: 360)
        .frame(minHeight: 44)
        .background(PerryTheme.Colors.surface, in: RoundedRectangle(cornerRadius: PerryTheme.Radius.panel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PerryTheme.Radius.panel, style: .continuous)
                .strokeBorder(focused || listener.listening ? PerryTheme.Colors.accent.opacity(0.5) : PerryTheme.Colors.subtleSeparator)
        }
        .task(id: index) {
            await Task.yield()
            focused = true
        }
    }

    @ViewBuilder
    private func chips(_ index: Int) -> some View {
        let options = switch model.kind(at: index) {
        case .work: InterviewModel.workChips
        case .apps: appChips
        case .intro, .goal, .followUp: [String]()
        }
        if !options.isEmpty {
            ViewThatFits(in: .horizontal) {
                ForEach((1...options.count).reversed(), id: \.self) { count in
                    HStack(spacing: 6) {
                        ForEach(options.prefix(count), id: \.self) { option in
                            Button(option) {
                                if model.kind(at: index) == .apps {
                                    let current = model.draft.trimmingCharacters(in: .whitespaces)
                                    model.draft = current.isEmpty ? option : current + ", " + option
                                } else {
                                    model.answer(option)
                                }
                            }
                            .buttonStyle(ChipStyle())
                            .fixedSize()
                        }
                    }
                }
            }
        }
    }

    private var importOffer: some View {
        OnboardingBeatLayout(title: "Do you use ChatGPT or Claude?", message: "I can open it and read what it remembers about you.") {
            EmptyView()
        } detail: {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    ForEach(InterviewModel.MemoryService.allCases, id: \.self) { service in
                        Button { model.chooseImport(service) } label: {
                            HStack(spacing: 6) {
                                let id = service == .chatGPT ? "chatgpt" : "claude"
                                if Self.installedAssistants.contains(id) { BrandMark(id: id, size: 16) }
                                Text(service.rawValue)
                            }
                        }
                        .buttonStyle(ChipStyle())
                    }
                }
                spokenAnswer
            }
        } actions: {
            OnboardingFooter {
                EmptyView()
            } primary: {
                Button("Neither") { model.chooseImport(nil) }
            } trailing: {
                EmptyView()
            }
        }
        .task {
            model.draft = ""
            await model.say("Do you use ChatGPT or Claude? I can open it and read what it remembers about you.")
            guard model.listensAfterSpeaking, !Task.isCancelled else { return }
            listener.start(onPartial: { model.draft = $0 }, onDone: { text in
                model.draft = text
                model.chooseImport(InterviewModel.MemoryService.heard(text))
            })
        }
    }

    private func importConsent(_ service: InterviewModel.MemoryService) -> some View {
        let question = "Can I open \(service.rawValue) and read your memory?"
        return OnboardingBeatLayout(title: question, message: "I’ll open its memory page and read it. I won’t change anything.") {
            EmptyView()
        } detail: {
            spokenAnswer
        } actions: {
            OnboardingFooter {
                EmptyView()
            } primary: {
                Button { model.allowImport(true) } label: { OnboardingPrimaryLabel(title: "Open \(service.rawValue)") }
                    .buttonStyle(InkButtonStyle())
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            } trailing: {
                Button("Not now") { model.allowImport(false) }
            }
        }
        .task {
            model.draft = ""
            await model.say("\(question) I won’t change anything.")
            guard model.listensAfterSpeaking, !Task.isCancelled else { return }
            listener.start(onPartial: { model.draft = $0 }, onDone: { text in
                model.draft = text
                if let allowed = InterviewModel.heardYes(text) { model.allowImport(allowed) }
            })
        }
    }

    private func importing(_ service: InterviewModel.MemoryService) -> some View {
        OnboardingBeatLayout(title: "Reading what \(service.rawValue) remembers…", message: "If it asks you to sign in, sign in and I’ll carry on.") {
            EmptyView()
        } detail: {
            ProgressView().controlSize(.small)
        } actions: {
            OnboardingFooter {
                EmptyView()
            } primary: {
                Button("Skip") { model.cancelImport() }
            } trailing: {
                EmptyView()
            }
        }
    }

    private var summary: some View {
        OnboardingBeatLayout(title: "Did I get that right?", message: model.thinking ? "Fixing it…" : nil) {
            EmptyView()
        } detail: {
            VStack(spacing: 12) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.summaryLines, id: \.self) { line in
                            Text(line)
                                .font(PerryTheme.Scale.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .frame(maxHeight: 160)
                .fixedSize(horizontal: false, vertical: true)
                .background(PerryTheme.Colors.surface, in: RoundedRectangle(cornerRadius: PerryTheme.Radius.card, style: .continuous))
                .multilineTextAlignment(.leading)
                if typing {
                    TextField("What should I change?", text: $model.draft)
                        .textFieldStyle(.plain)
                        .font(PerryTheme.Scale.input)
                        .focused($focused)
                        .focusEffectDisabled()
                        .onSubmit { model.correct(model.draft) }
                        .padding(.horizontal, 16)
                        .frame(width: 360, height: 44)
                        .background(PerryTheme.Colors.surface, in: RoundedRectangle(cornerRadius: PerryTheme.Radius.panel, style: .continuous))
                        .task { focused = true }
                } else {
                    spokenAnswer
                }
            }
        } actions: {
            OnboardingFooter {
                EmptyView()
            } primary: {
                if !listener.listening {
                    Button { model.confirmSummary() } label: { OnboardingPrimaryLabel(title: "That’s right") }
                        .buttonStyle(InkButtonStyle())
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.thinking)
                }
            } trailing: {
                if !typing {
                    Button("Type") {
                        listener.stop()
                        typing = true
                    }
                }
            }
        }
        .task {
            typing = false
            model.draft = ""
            await model.say(model.spokenSummary)
            hearSummaryAnswer()
        }
    }

    private func hearSummaryAnswer() {
        guard model.listensAfterSpeaking, !typing else { return }
        listener.start(onPartial: { model.draft = $0 }, onDone: { text in
            model.draft = text
            switch InterviewModel.heardYes(text) {
            case true?:
                model.confirmSummary()
            case false? where text.split(separator: " ").count <= 2:
                model.draft = ""
                Task {
                    await model.say("What should I change?")
                    hearSummaryAnswer()
                }
            default:
                model.correct(text)
            }
        })
    }
}
