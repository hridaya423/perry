import PerryOverlay
import SwiftUI

struct NotchListeningView: View {
    @ObservedObject var voice: TalkSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("perry.voice.pauseHintUses") private var pauseHintUses = 0
    @State private var showsPauseHint = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                HStack(alignment: .center, spacing: 14) {
                    ring
                    VStack(alignment: .leading, spacing: 3) {
                        Text(headline)
                            .font(PerryTheme.Scale.title)
                            .foregroundStyle(voice.clickState == .failed ? PerryTheme.Colors.warning : PerryTheme.Colors.text)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                        if let detail {
                            Text(detail)
                                .font(PerryTheme.Scale.secondary)
                                .foregroundStyle(PerryTheme.Colors.textSecondary)
                                .lineLimit(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
                .onTapGesture { voice.sendNow() }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(voice.clickState == .listening ? .isButton : [])
                .accessibilityHint(voice.clickState == .listening ? "Sends what you said" : "")

                if voice.clickState == .listening {
                    Button(action: voice.sendNow) {
                        Image(systemName: "arrow.up")
                            .font(PerryTheme.Icon.toolbar)
                            .foregroundStyle(PerryTheme.Colors.onPrimaryAction)
                            .frame(width: 28, height: 28)
                            .background(PerryTheme.Colors.primaryAction, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel("Send now")
                    .help("Send now (Return)")
                }
                WindowControlButton(systemImage: "xmark", label: "Cancel (Esc)") {
                    voice.clickState == .failed ? voice.resetConversation() : voice.cancelClick()
                }
                .keyboardShortcut(.cancelAction)
            }
            if voice.clickState == .failed {
                Button("Try again") { voice.startClick() }
                    .buttonStyle(InkButtonStyle(.secondary))
                    .controlSize(.small)
            }
        }
        .onAppear {
            if voice.clickState == .listening { countPauseHint() }
        }
        .onChange(of: voice.clickState) { _, state in
            switch state {
            case .listening:
                countPauseHint()
                AccessibilityNotification.Announcement("Listening").post()
            case .thinking: AccessibilityNotification.Announcement("Sending. Thinking").post()
            default: break
            }
        }
    }

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(PerryTheme.Colors.accent.opacity(listening ? 0.25 + 0.5 * voice.level : 0.2), lineWidth: 2)
                .scaleEffect(listening && !reduceMotion ? 1 + 0.16 * voice.level : 1)
            if listening, voice.endProgress > 0 {
                if reduceMotion {
                    Circle()
                        .stroke(PerryTheme.Colors.accent, lineWidth: 2)
                        .opacity(voice.endProgress < 0.5 ? 0.9 : 0.4)
                } else {
                    Circle()
                        .trim(from: 0, to: 1 - voice.endProgress)
                        .stroke(PerryTheme.Colors.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            }
            PerryCharacter(mood: .resting, size: 26)
                .accessibilityHidden(true)
        }
        .frame(width: 48, height: 48)
        .animation(reduceMotion ? nil : .linear(duration: 0.05), value: voice.level)
    }

    private var listening: Bool { voice.clickState == .listening }

    private func countPauseHint() {
        showsPauseHint = pauseHintUses < 3
        pauseHintUses += 1
    }

    private var headline: String {
        switch voice.clickState {
        case .idle, .requestingPermission: "Getting the microphone…"
        case .listening: voice.transcript.isEmpty ? "Listening…" : voice.transcript
        case .thinking: voice.transcript.isEmpty ? "Thinking…" : voice.transcript
        case .speaking: voice.answer.isEmpty ? "Speaking…" : voice.answer
        case .failed: voice.error ?? "Voice failed."
        }
    }

    private var detail: String? {
        switch voice.clickState {
        case .listening: showsPauseHint ? "Pause when you’re done." : nil
        case .thinking: voice.transcript.isEmpty ? nil : "Thinking…"
        default: nil
        }
    }
}
