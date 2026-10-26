import AppKit
import PerryBrain
import PerryCore
import SwiftUI

@MainActor
final class InterviewModel: ObservableObject {
    enum Step: Equatable {
        case consent, question(Int), review, done
    }

    struct Facts: Equatable {
        var name = ""
        var work = ""
        var apps = ""
        var goal = ""
    }

    struct Effects {
        var complete: ((String) async throws -> String)?
        var save: (Facts) -> Void = { _ in }
    }

    static let knownApps = ["Notion", "Figma", "Xcode", "Slack", "Linear", "Visual Studio Code", "Cursor", "Safari", "Google Chrome", "Arc", "Mail", "Microsoft Word", "Keynote"]
    static let workChips = ["Student", "Designer", "Developer", "Founder"]

    static func appChips(installed: (String) -> Bool = { FileManager.default.fileExists(atPath: "/Applications/\($0).app") }) -> [String] {
        Array(knownApps.filter(installed).prefix(5))
    }

    static func cloudLine(choice: BrainController.ModelChoice, hasSavedChoice: Bool) -> String? {
        guard hasSavedChoice else { return nil }
        let provider: String? = switch choice {
        case .chatGPT: "ChatGPT"
        case .claudeCode: "Claude Code"
        case .acp: "your agent"
        case .direct: "your API provider"
        case .local: nil
        }
        return provider.map { "I send these notes with your questions to \($0)." }
    }

    @Published private(set) var step = Step.consent
    @Published private(set) var reaction: String?
    @Published private(set) var extracting = false
    @Published var draft = ""
    @Published var facts: Facts

    private var answers: [String?] = Array(repeating: nil, count: ProfileExtraction.questions.count)
    private let effects: Effects

    init(name: String, effects: Effects) {
        self.facts = Facts(name: name)
        self.effects = effects
    }

    func begin() {
        guard step == .consent else { return }
        step = .question(0)
    }

    func answer(_ text: String?) {
        guard case .question(let index) = step else { return }
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let answer = trimmed.isEmpty ? nil : trimmed
        answers[index] = answer
        draft = ""
        reaction = nil
        guard index + 1 < answers.count else { return finishQuestions() }
        step = .question(index + 1)
        if let answer, let complete = effects.complete {
            let next = step
            Task {
                let text = try? await complete(ProfileExtraction.reactionPrompt(question: ProfileExtraction.questions[index], answer: answer))
                guard step == next else { return }
                reaction = text.flatMap(ProfileExtraction.trimReaction)
            }
        }
    }

    func confirm() {
        guard step == .review else { return }
        effects.save(facts)
        step = .done
    }

    func cancel() {
        step = .done
    }

    private func finishQuestions() {
        guard answers.contains(where: { $0 != nil }) else {
            step = .done
            return
        }
        facts.work = answers[0] ?? ""
        facts.apps = answers[1] ?? ""
        facts.goal = answers[2] ?? ""
        step = .review
        guard let complete = effects.complete else { return }
        let typed = facts
        extracting = true
        Task {
            defer { extracting = false }
            guard let text = try? await complete(ProfileExtraction.prompt(answers: answers)),
                  let extracted = try? ProfileExtraction.decode(text),
                  step == .review, facts == typed else { return }
            facts.work = extracted.work ?? typed.work
            facts.apps = extracted.apps.isEmpty ? typed.apps : extracted.apps.joined(separator: ", ")
            facts.goal = extracted.learningGoal ?? typed.goal
        }
    }
}

extension AppController {
    func saveInterview(_ facts: InterviewModel.Facts) async {
        guard let files = memoryFiles else { return }
        for (field, value) in [("Name", facts.name), ("Work", facts.work), ("Apps", facts.apps), ("Learning goal", facts.goal)] {
            try? files.setProfileField(field, value)
        }
        await setMemoryEnabled(true)
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
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            switch model.step {
            case .consent: consent
            case .question(let index): question(index)
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
            message: (["Three quick questions. I keep short notes on this Mac so I can help your way, and you can delete them any time."] + [cloudLine].compactMap { $0 }).joined(separator: " "),
            artHeight: 64
        ) {
            Color.clear
        } detail: {
            EmptyView()
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

    private func question(_ index: Int) -> some View {
        OnboardingBeatLayout(title: ProfileExtraction.questions[index], message: model.reaction, artHeight: 40) {
            Color.clear
        } detail: {
            VStack(spacing: 12) {
                answerField(index)
                chips(index)
            }
        } actions: {
            OnboardingFooter {
                OnboardingProgress(current: index, count: ProfileExtraction.questions.count)
                    .padding(.trailing, 10)
            } primary: {
                Button { model.answer(model.draft) } label: { OnboardingPrimaryLabel(title: "Next") }
                    .buttonStyle(InkButtonStyle())
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.draft.trimmingCharacters(in: .whitespaces).isEmpty)
            } trailing: {
                Button("Skip") { model.answer(nil) }
            }
        }
        .id(index)
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
        let options = index == 0 ? InterviewModel.workChips : index == 1 ? appChips : []
        if !options.isEmpty {
            HStack(spacing: 6) {
                ForEach(options, id: \.self) { option in
                    Button(option) {
                        if index == 1 {
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
        OnboardingBeatLayout(title: "Here’s what I got.", message: model.extracting ? "Tidying up…" : "Not saved yet.") {
            Color.clear
        } detail: {
            VStack(spacing: 0) {
                fact("Name", $model.facts.name)
                SettingsDivider()
                fact("Work", $model.facts.work)
                SettingsDivider()
                fact("Apps", $model.facts.apps)
                SettingsDivider()
                fact("Learning", $model.facts.goal)
            }
            .padding(.vertical, 2)
            .background(PerryTheme.Colors.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(PerryTheme.Colors.subtleSeparator, lineWidth: 1)
            }
        } actions: {
            OnboardingFooter {
                Button(editing ? "Done" : "Edit") { editing.toggle() }
            } primary: {
                Button { model.confirm() } label: { OnboardingPrimaryLabel(title: "Looks right") }
                    .buttonStyle(InkButtonStyle())
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            } trailing: {
                Button("Don’t save") { model.cancel() }
            }
        }
    }

    private func fact(_ label: String, _ value: Binding<String>) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(PerryTheme.Scale.secondary)
                .foregroundStyle(PerryTheme.Colors.textSecondary)
                .frame(width: 70, alignment: .leading)
            if editing {
                TextField(label, text: value)
                    .textFieldStyle(.plain)
                    .font(PerryTheme.Scale.body)
            } else {
                Text(value.wrappedValue.isEmpty ? "—" : value.wrappedValue)
                    .font(PerryTheme.Scale.body)
                    .foregroundStyle(value.wrappedValue.isEmpty ? PerryTheme.Colors.textTertiary : PerryTheme.Colors.text)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}
