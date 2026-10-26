import PerryOverlay
import SwiftUI

struct NotchListeningView: View {
    @ObservedObject var voice: TalkSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(PerryPreferences.$pauseHintUses.key) private var pauseHintUses = 0
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
                    meter
                    Button(action: voice.sendNow) {
                        Image(systemName: "arrow.up")
                            .font(PerryTheme.Icon.status)
                            .foregroundStyle(PerryTheme.Colors.onPrimaryAction)
                            .frame(width: PerryTheme.Icon.hit, height: PerryTheme.Icon.hit)
                            .background(PerryTheme.Colors.primaryAction, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel("Send now")
                    .help("Send now (Return)")
                }
                WindowControlButton(systemImage: "xmark", label: "Cancel") {
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
        var pose = PerryCharacterPose()
        pose.face = voice.clickState == .failed ? .worried : listening ? .open : .focused
        return PerryCharacterView(pose: pose, size: 26)
            .frame(width: 44, height: 44)
            .background(PerryCharacterView.fern.opacity(listening ? 0.14 + 0.22 * voice.level : 0.12),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: voice.level)
            .accessibilityHidden(true)
    }

    private var meter: some View {
        HStack(spacing: 3) {
            ForEach(Array([0.55, 1, 0.75, 0.4].enumerated()), id: \.offset) { _, weight in
                Capsule()
                    .fill(PerryTheme.Colors.accent)
                    .frame(width: 3, height: 4 + 16 * min(voice.level * 1.4, 1) * weight)
            }
        }
        .frame(height: 20)
        .opacity(1 - 0.6 * voice.endProgress)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: voice.level)
        .accessibilityHidden(true)
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
        case .failed: voice.error ?? "I couldn’t hear that. Try again."
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
