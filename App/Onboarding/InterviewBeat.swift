import AppKit
import PerryBrain
import PerryCore
import PerryGuide
import SwiftUI

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
