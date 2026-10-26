import AppKit
import PerryBrain
import PerryCore
import PerryGuide
import SwiftUI

@MainActor
final class InterviewModel: ObservableObject {
    enum Step: Equatable {
        case consent, importNotes, pronounce, question(Int), style, review, done
    }

    enum Kind: Equatable {
        case work, apps, goal, followUp
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
        var now: () -> Date = Date.init
    }

    static let knownApps = ["Notion", "Figma", "Xcode", "Slack", "Linear", "Visual Studio Code", "Cursor", "Safari", "Google Chrome", "Arc", "Mail", "Microsoft Word", "Keynote"]
    static let workChips = ["Student", "Designer", "Developer", "Founder"]
    static let styles = ["Short and direct", "More detail"]

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

    @Published private(set) var step = Step.consent
    @Published private(set) var reaction: String?
    @Published private(set) var extracting = false
    @Published private(set) var thinking = false
    @Published var draft = ""
    @Published var facts: Facts
    @Published var notes: [Note] = []
    @Published var pasted = ""

    private(set) var questions = ProfileExtraction.questions
    private var kinds: [Kind] = [.work, .apps, .goal]
    private var answers: [String?] = Array(repeating: nil, count: ProfileExtraction.questions.count)
    private var startedAt: Date?
    private var shortStreak = 0
    private let effects: Effects

    init(name: String, effects: Effects) {
        self.facts = Facts(name: name)
        self.effects = effects
    }

    var canImport: Bool { effects.complete != nil }
    var questionCount: Int { questions.count }

    func begin() {
        guard step == .consent || step == .importNotes else { return }
        startedAt = effects.now()
        step = facts.name.isEmpty ? .question(0) : .pronounce
    }

    func startImport() {
        guard step == .consent, canImport else { return }
        step = .importNotes
    }

    func readImport() {
        guard step == .importNotes, let complete = effects.complete else { return }
        let text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return begin() }
        extracting = true
        Task {
            defer { extracting = false }
            let reply = try? await complete(MemoryExtraction.importPrompt(text))
            notes += (reply.map(MemoryExtraction.decodeImport) ?? []).map { Note(fact: $0) }
            pasted = ""
            begin()
        }
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

    func chooseStyle(_ style: String?) {
        guard step == .style else { return }
        facts.style = style ?? ""
        step = .review
        extract()
    }

    func confirm() {
        guard step == .review else { return }
        effects.save(facts)
        effects.saveNotes(notes.filter(\.kept).map(\.fact))
        step = .done
    }

    func cancel() {
        step = .done
    }

    private func finishQuestions() {
        guard answers.contains(where: { $0 != nil }) || !notes.isEmpty || !facts.spoken.isEmpty else {
            step = .done
            return
        }
        for (kind, answer) in zip(kinds, answers) {
            switch kind {
            case .work: facts.work = answer ?? ""
            case .apps: facts.apps = answer ?? ""
            case .goal: facts.goal = answer ?? ""
            case .followUp: break
            }
        }
        step = .style
    }

    private func extract() {
        guard let complete = effects.complete else { return }
        let typed = facts
        let core = zip(kinds, answers).filter { $0.0 != .followUp }.map(\.1)
        let followUps = zip(zip(questions, answers), kinds).filter { $0.1 == .followUp }.compactMap { pair in
            pair.0.1.map { "Q: \(pair.0.0)\nA: \($0)" }
        }
        extracting = true
        Task {
            defer { extracting = false }
            if let text = try? await complete(ProfileExtraction.prompt(answers: core)),
               let extracted = try? ProfileExtraction.decode(text), step == .review, facts == typed {
                facts.work = extracted.work ?? typed.work
                facts.apps = extracted.apps.isEmpty ? typed.apps : extracted.apps.joined(separator: ", ")
                facts.goal = extracted.learningGoal ?? typed.goal
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
    @State private var editing = false
    @State private var copied = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            switch model.step {
            case .consent: consent
            case .importNotes: importNotes
            case .pronounce: pronounce
            case .question(let index): question(index)
            case .style: style
            case .review: review
            case .done: Color.clear
            }
        }
        .onChange(of: model.step) { _, step in
            listener.stop()
            if step == .done { director.skip() }
        }
        .onDisappear { listener.stop() }
    }

    private var consent: some View {
        OnboardingBeatLayout(
            title: "Tell me about you.",
            message: (["A few quick questions. I keep notes on this Mac, and you can delete them any time."] + [cloudLine].compactMap { $0 }).joined(separator: " ")
        ) {
            Color.clear
        } detail: {
            if model.canImport {
                Button { model.startImport() } label: {
                    Label("Bring notes from ChatGPT or Claude", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(ChipStyle())
            }
        } actions: {
            OnboardingFooter {
                EmptyView()
            } primary: {
                Button { model.begin() } label: { OnboardingPrimaryLabel(title: "Start") }
                    .buttonStyle(InkButtonStyle())
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            } trailing: {
                Button("Skip") { model.cancel() }
            }
        }
    }

    private var importNotes: some View {
        OnboardingBeatLayout(title: "Bring your notes over", message: "Ask ChatGPT or Claude this, then paste the answer here.") {
            Color.clear
        } detail: {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Text(MemoryExtraction.importRequest)
                        .font(PerryTheme.Scale.secondary)
                        .foregroundStyle(PerryTheme.Colors.text)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(MemoryExtraction.importRequest, forType: .string)
                        copied = true
                    }
                    .buttonStyle(InkButtonStyle(.secondary))
                    .controlSize(.small)
                }
                .padding(10)
                .background(PerryTheme.Colors.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                TextEditor(text: $model.pasted)
                    .font(PerryTheme.Scale.secondary)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 72)
                    .background(PerryTheme.Colors.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if model.pasted.isEmpty {
                            Text("Paste the answer").font(PerryTheme.Scale.secondary).foregroundStyle(PerryTheme.Colors.textTertiary)
                                .padding(.horizontal, 11).padding(.vertical, 6).allowsHitTesting(false)
                        }
                    }
            }
            .multilineTextAlignment(.leading)
        } actions: {
            OnboardingFooter {
                EmptyView()
            } primary: {
                Button { model.readImport() } label: { OnboardingPrimaryLabel(title: model.extracting ? "Reading…" : "Continue") }
                    .buttonStyle(InkButtonStyle())
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.extracting)
            } trailing: {
                Button("Skip") { model.begin() }
            }
        }
    }

    private var pronounce: some View {
        OnboardingBeatLayout(title: "How do you say \(model.facts.name)?", message: "Listen to my try. If it is wrong, spell it the way it sounds.") {
            Color.clear
        } detail: {
            HStack(spacing: 8) {
                Button { model.sayName() } label: {
                    Image(systemName: "play.fill")
                        .frame(width: PerryTheme.Icon.hit, height: PerryTheme.Icon.hit)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(PerryTheme.Colors.accent)
                .accessibilityLabel("Hear Perry say your name")
                TextField("For example, Hrid-yah", text: $model.draft)
                    .textFieldStyle(.plain)
                    .font(PerryTheme.Scale.input)
                    .focused($focused)
                    .focusEffectDisabled()
                    .onSubmit { model.confirmPronunciation() }
            }
            .padding(.horizontal, 10)
            .frame(width: 360, height: 44)
            .background(PerryTheme.Colors.surface, in: RoundedRectangle(cornerRadius: 22))
            .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(focused ? PerryTheme.Colors.accent.opacity(0.5) : PerryTheme.Colors.subtleSeparator) }
            .task { model.sayName() }
        } actions: {
            OnboardingFooter {
                EmptyView()
            } primary: {
                Button { model.confirmPronunciation() } label: { OnboardingPrimaryLabel(title: model.draft.isEmpty ? "Sounds right" : "Save") }
                    .buttonStyle(InkButtonStyle())
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            } trailing: {
                if !model.draft.isEmpty {
                    Button("Hear it") { model.sayName(spelled: model.draft) }
                }
            }
        }
    }

    private func question(_ index: Int) -> some View {
        OnboardingBeatLayout(title: model.questions[index], message: model.reaction) {
            Color.clear
        } detail: {
            VStack(spacing: 12) {
                answerField(index)
                chips(index)
            }
        } actions: {
            OnboardingFooter {
                OnboardingProgress(current: index, count: model.questionCount)
                    .padding(.trailing, 10)
            } primary: {
                Button { model.answer(model.draft) } label: { OnboardingPrimaryLabel(title: model.thinking ? "One sec…" : "Continue") }
                    .buttonStyle(InkButtonStyle())
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.thinking || model.draft.trimmingCharacters(in: .whitespaces).isEmpty)
            } trailing: {
                Button("Skip") { model.answer(nil) }
                    .disabled(model.thinking)
            }
        }
        .id(index)
    }

    private var style: some View {
        OnboardingBeatLayout(title: "How should I answer?", message: "You can change this any time.") {
            Color.clear
        } detail: {
            Color.clear.frame(height: 0)
        } actions: {
            OnboardingFooter {
                EmptyView()
            } primary: {
                Button { model.chooseStyle(InterviewModel.styles[0]) } label: { OnboardingPrimaryLabel(title: "Short and direct") }
                    .buttonStyle(InkButtonStyle())
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            } trailing: {
                Button(InterviewModel.styles[1]) { model.chooseStyle(InterviewModel.styles[1]) }
            }
        }
    }

    private func answerField(_ index: Int) -> some View {
        HStack(spacing: 8) {
            TextField(listener.listening ? "Listening…" : "Type or tap the mic", text: $model.draft)
                .textFieldStyle(.plain)
                .font(PerryTheme.Scale.input)
                .focused($focused)
                .focusEffectDisabled()
                .onSubmit { model.answer(model.draft) }
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
            .buttonStyle(.plain)
            .accessibilityLabel(listener.listening ? "Stop listening" : "Answer by voice")
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .frame(width: 360, height: 44)
        .background(PerryTheme.Colors.surface, in: RoundedRectangle(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22)
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
        case .goal, .followUp: [String]()
        }
        if !options.isEmpty {
            HStack(spacing: 6) {
                ForEach(options, id: \.self) { option in
                    Button(option) {
                        if model.kind(at: index) == .apps {
                            let current = model.draft.trimmingCharacters(in: .whitespaces)
                            model.draft = current.isEmpty ? option : current + ", " + option
                        } else {
                            model.answer(option)
                        }
                    }
                    .buttonStyle(ChipStyle())
                }
            }
        }
    }

    private var review: some View {
        OnboardingBeatLayout(title: "What I know about you", message: model.extracting ? "Tidying up…" : "I haven’t saved this yet.") {
            Color.clear
        } detail: {
            ScrollView {
                VStack(spacing: 0) {
                    fact("Name", $model.facts.name, play: model.facts.name.isEmpty ? nil : { model.sayName() })
                    SettingsDivider()
                    fact("Work", $model.facts.work)
                    SettingsDivider()
                    fact("Apps", $model.facts.apps)
                    SettingsDivider()
                    fact("Learning goal", $model.facts.goal)
                    SettingsDivider()
                    fact("Answers", $model.facts.style)
                    ForEach($model.notes) { $note in
                        SettingsDivider()
                        Toggle(isOn: $note.kept) {
                            Text(note.fact.text).font(PerryTheme.Scale.body).lineLimit(2)
                        }
                        .toggleStyle(.checkbox)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 220)
            .fixedSize(horizontal: false, vertical: true)
            .background(PerryTheme.Colors.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(PerryTheme.Colors.subtleSeparator, lineWidth: 1)
            }
        } actions: {
            OnboardingFooter {
                Button(editing ? "Done" : "Edit") { editing.toggle() }
            } primary: {
                Button { model.confirm() } label: { OnboardingPrimaryLabel(title: "Save") }
                    .buttonStyle(InkButtonStyle())
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            } trailing: {
                Button("Don’t save") { model.cancel() }
            }
        }
    }

    private func fact(_ label: String, _ value: Binding<String>, play: (() -> Void)? = nil) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(PerryTheme.Scale.secondary)
                .foregroundStyle(PerryTheme.Colors.textSecondary)
                .frame(width: 96, alignment: .leading)
            if editing {
                TextField(label, text: value)
                    .textFieldStyle(.plain)
                    .font(PerryTheme.Scale.body)
            } else {
                Text(value.wrappedValue.isEmpty ? "Skipped" : value.wrappedValue)
                    .font(PerryTheme.Scale.body)
                    .foregroundStyle(value.wrappedValue.isEmpty ? PerryTheme.Colors.textTertiary : PerryTheme.Colors.text)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let play {
                Button(action: play) { Image(systemName: "play.fill").imageScale(.small) }
                    .buttonStyle(.plain)
                    .foregroundStyle(PerryTheme.Colors.icon)
                    .accessibilityLabel("Hear your name")
            }
        }
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}
