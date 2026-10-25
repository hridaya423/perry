import AppKit
import SwiftUI
import PerryGuide
import PerryOverlay

struct SessionPanelView: View {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("perry.session")
    @ObservedObject var controller: AppController

    private enum InvocationMode: String, CaseIterable {
        case ask
        case guide
        case do_

        var prompt: String {
            switch self {
            case .ask: return "What should Perry explain?"
            case .guide: return "What should Perry show you?"
            case .do_: return "What should Perry take off your hands?"
            }
        }

        var subtitle: String {
            switch self {
            case .ask: return "here. I look, I tell you."
            case .guide: return "here. I point, you click."
            case .do_: return "here. I work, you supervise."
            }
        }
    }

    @State private var mode = InvocationMode.ask
    @State private var skipIntentParse = false
    @State private var text = ""
    @State private var runInBackground = false
    @FocusState private var fieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            panelContent
                .padding(PerryTheme.Spacing.panelInset)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: PerryTheme.Sizing.panelWidth)
        .background(PerryTheme.Colors.canvas)
        .tint(PerryTheme.Colors.accent)
        .foregroundStyle(PerryTheme.Colors.text)
        .onAppear {
            consumePendingPrompt()
        }
        .onChange(of: controller.pendingPromptText) { _, _ in
            consumePendingPrompt()
        }
        .task {
            await Task.yield()
            fieldFocused = NSApp.keyWindow?.identifier == Self.windowIdentifier
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window.identifier == Self.windowIdentifier else { return }
            DispatchQueue.main.async {
                guard NSApp.keyWindow?.identifier == Self.windowIdentifier else { return }
                fieldFocused = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window.identifier == Self.windowIdentifier else { return }
            fieldFocused = false
        }
        .onChange(of: text) { _, newValue in
            // A rehearsal Edit prefill already knows its mode — don't let the
            // parser second-guess it.
            if skipIntentParse { skipIntentParse = false; return }
            switch GuideIntentParser.parse(newValue) {
            case .doTask: mode = .do_
            case .guide, .showEverything: mode = .guide
            case .dismiss, .notAGuideRequest: break
            }
        }
        .onChange(of: mode) { _, _ in
            if NSApp.keyWindow?.identifier == Self.windowIdentifier {
                fieldFocused = true
            }
        }
    }

    private var panelContent: some View {
        VStack(alignment: .leading, spacing: PerryTheme.Spacing.section) {
            HStack(spacing: PerryTheme.Spacing.header) {
                PerryCharacterView(pose: PerryCharacterPose(), size: 24)
                VStack(alignment: .leading, spacing: PerryTheme.Spacing.label) {
                    Text("Perry")
                        .font(PerryTheme.Typography.panelTitle)
                    Text(mode.subtitle)
                        .font(PerryTheme.Typography.panelSubtitle)
                        .foregroundStyle(PerryTheme.Colors.textSecondary)
                }
                Spacer()
                Button {
                    controller.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(PerryTheme.Typography.panelClose)
                        .foregroundStyle(PerryTheme.Colors.textSecondary)
                        .frame(width: PerryTheme.Sizing.iconButton, height: PerryTheme.Sizing.iconButton)
                        .background(PerryTheme.Colors.canvas, in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close session panel")
                .accessibilityHint("Dismiss Perry’s request panel")
            }

            Picker("Ask, Guide, or Do", selection: $mode) {
                Text("Ask").tag(InvocationMode.ask)
                Text("Guide").tag(InvocationMode.guide)
                Text("Do").tag(InvocationMode.do_)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(controller.isTaskActive)
            .accessibilityLabel("Ask, Guide, or Do")

            HStack(spacing: PerryTheme.Spacing.control) {
                TextField(mode.prompt, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .font(PerryTheme.Typography.panelBody)
                    .focused($fieldFocused)
                    .onSubmit { submit() }
                    .disabled(controller.isTaskActive)
                    .accessibilityLabel("Task request")
                    .accessibilityHint("Describe what you want Perry to show, explain, or take over")

                Button {
                    controller.voice.beginDictation()
                } label: {
                    Image(systemName: "mic.fill")
                        .font(PerryTheme.Typography.panelIcon)
                        .foregroundStyle(PerryTheme.Colors.textSecondary)
                        .frame(width: PerryTheme.Sizing.iconButton, height: PerryTheme.Sizing.iconButton)
                        .background(PerryTheme.Colors.canvas, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Start dictation")
                .accessibilityLabel("Start dictation")
                .accessibilityHint("Speak the task request")
            }

            if mode == .do_ && !controller.isTaskActive {
                HStack(spacing: PerryTheme.Spacing.inline) {
                    Toggle("Run in background", isOn: $runInBackground)
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .font(PerryTheme.Typography.panelMetadata)
                    Spacer()
                }
            }

            HStack(spacing: PerryTheme.Spacing.control) {
                Circle()
                    .fill(controller.isTaskActive ? PerryTheme.Colors.accent : PerryTheme.Colors.textSecondary)
                    .frame(width: PerryTheme.Sizing.statusDot, height: PerryTheme.Sizing.statusDot)
                    .accessibilityHidden(true)
                Text(controller.sessionStatus)
                    .font(PerryTheme.Typography.panelMetadata)
                    .foregroundStyle(PerryTheme.Colors.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Session status")
                    .accessibilityValue(controller.sessionStatus)
                Spacer()
                if let progress = controller.taskProgress, controller.isTaskActive {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(width: PerryTheme.Sizing.progressWidth)
                        .accessibilityLabel("Task progress")
                        .accessibilityValue("\(Int(progress * 100)) percent")
                }
            }

            if case .asking(let ask) = controller.sessionState, let input = ask.pendingGuideRequest {
                GroupBox("Guide request") {
                    Text(input.text)
                        .font(PerryTheme.Typography.panelBody)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if !controller.transcriptPreview.isEmpty {
                Text(controller.transcriptPreview)
                    .font(PerryTheme.Typography.panelSubtitle)
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Latest transcript")
                    .accessibilityValue(controller.transcriptPreview)
            }

            if controller.isTaskActive {
                Text("Pause, steer, or stop from the status strip.")
                    .font(PerryTheme.Typography.panelMetadata)
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            } else {
                if case .failed = controller.sessionState {
                    HStack(spacing: PerryTheme.Spacing.control) {
                        Button("Retry task") { controller.foreground.retry() }
                            .buttonStyle(InkButtonStyle(.secondary))
                            .controlSize(.small)
                        Spacer()
                    }
                }

                if case .asking(let ask) = controller.sessionState {
                    VStack(alignment: .leading, spacing: PerryTheme.Spacing.inline) {
                        if let answer = ask.answerText {
                            Text(answer)
                                .font(PerryTheme.Typography.panelBody)
                                .foregroundStyle(PerryTheme.Colors.text)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityLabel("Perry’s answer")
                        }
                        if let followUp = ask.followUpPrompt {
                            Text("Try: \(followUp)")
                                .font(PerryTheme.Typography.panelMetadata)
                                .foregroundStyle(PerryTheme.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Button { submit() } label: {
                    Text(startTitle)
                        .font(PerryTheme.Typography.action)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(InkButtonStyle())
                .disabled(requestIsEmpty)
                .keyboardShortcut(.defaultAction)
                .accessibilityHint("Submit the request to Perry")
            }
        }
        .animation(reduceMotion ? nil : PerryTheme.Motion.panelStateChange, value: controller.isTaskActive)
        .animation(reduceMotion ? nil : PerryTheme.Motion.panelStateChange, value: mode)
    }

    private var startTitle: String {
        switch mode {
        case .ask:
            if case .asking = controller.sessionState { return "Ask follow-up" }
            return "Ask"
        case .guide: return "Start guiding"
        case .do_: return runInBackground ? "Queue task" : "Start"
        }
    }

    private var requestIsEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func consumePendingPrompt() {
        guard let prefill = controller.pendingPromptText else { return }
        controller.pendingPromptText = nil
        if controller.pendingPromptDoMode {
            skipIntentParse = true
            mode = .do_
        }
        if controller.pendingPromptRunInBackground {
            runInBackground = true
        }
        controller.pendingPromptDoMode = false
        controller.pendingPromptRunInBackground = false
        text = prefill
    }

    private func submit() {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        text = ""
        SoundPlayer.play(.send)

        switch GuideIntentParser.parse(raw) {
        case .dismiss:
            controller.dismiss()
        case .doTask(let goal):
            if mode == .ask {
                controller.ask(question: raw)
            } else {
                dispatchDo(goal)
            }
        case .showEverything(let goal):
            if mode == .do_ {
                dispatchDo(raw)
            } else if mode == .ask {
                controller.ask(question: raw)
            } else {
                Task { await controller.showEverything(goal: goal) }
            }
        case .guide(let goal):
            if mode == .do_ {
                dispatchDo(raw)
            } else if mode == .ask {
                controller.ask(question: raw)
            } else {
                controller.startGuiding(goal: goal)
            }
        case .notAGuideRequest:
            if mode == .do_ {
                dispatchDo(raw)
            } else if mode == .ask {
                controller.ask(question: raw)
            } else {
                controller.startGuiding(goal: raw)
            }
        }
    }

    private func dispatchDo(_ goal: String) {
        if runInBackground {
            controller.backgroundTasks.queue(goal: goal)
        } else {
            controller.foreground.start(goal: goal)
        }
    }
}
