import PerryOverlay
import SwiftUI

struct Keycap: View {
    let keys: String

    init(_ keys: String) { self.keys = keys }

    var body: some View {
        Text(keys)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(PerryTheme.Colors.text)
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 20)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(PerryTheme.Colors.surface)
                    .shadow(color: .black.opacity(0.5), radius: 0, x: 0, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(PerryTheme.Colors.subtleSeparator, lineWidth: 1)
            )
    }
}

struct WorkspaceComposer: View {
    @Binding var text: String
    var placeholder = "Ask Perry anything"
    var canSend: Bool
    var focusOnAppear: Bool
    var onVoice: (() -> Void)?
    let send: () -> Void
    @FocusState private var focused: Bool
    @State private var dropTargeted = false

    private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(1...6)
                .focused($focused)
                .onSubmit { if hasText && canSend { send() } }
                .padding(.vertical, 5)
                .task(id: focusOnAppear) {
                    if focusOnAppear {
                        await Task.yield()
                        focused = true
                    }
                }
            if hasText {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(PerryTheme.Colors.onPrimaryAction)
                        .frame(width: 28, height: 28)
                        .background(PerryTheme.Colors.primaryAction, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel("Send")
                .help("Send (Return)")
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else if let onVoice {
                Button(action: onVoice) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(PerryTheme.Colors.text)
                        .frame(width: 28, height: 28)
                        .background(PerryTheme.Colors.subtleSeparator.opacity(0.7), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Talk to Perry")
                .help(TalkGesture.talk)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hasText)
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(PerryTheme.Colors.surface))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(focused || dropTargeted ? PerryTheme.Colors.accent.opacity(0.8) : PerryTheme.Colors.subtleSeparator, lineWidth: dropTargeted ? 2 : 1)
        )
        .animation(.easeOut(duration: 0.15), value: focused)
        .animation(.easeOut(duration: 0.15), value: dropTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            attach(urls)
        } isTargeted: { dropTargeted = $0 }
    }

    private func attach(_ urls: [URL]) -> Bool {
        let paths = urls.filter(\.isFileURL).map { url in
            let path = (url.path as NSString).abbreviatingWithTildeInPath
            return path.contains(" ") ? "\"\(path)\"" : path
        }
        guard !paths.isEmpty else { return false }
        let draft = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ([draft] + paths).filter { !$0.isEmpty }.joined(separator: " ") + " "
        focused = true
        return true
    }
}

struct ContextChipStyle: ButtonStyle {
    var iconOnly = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption)
            .labelStyle(ChipLabelStyle(iconOnly: iconOnly))
            .foregroundStyle(PerryTheme.Colors.textSecondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.1 : 0.05)))
            .overlay(Capsule().strokeBorder(PerryTheme.Colors.subtleSeparator, lineWidth: 1))
            .clipShape(Capsule())
    }
}

private struct ChipLabelStyle: LabelStyle {
    let iconOnly: Bool

    func makeBody(configuration: Configuration) -> some View {
        if iconOnly {
            Label(configuration).labelStyle(.iconOnly)
        } else {
            HStack(spacing: 5) {
                configuration.icon
                configuration.title
            }
        }
    }
}

struct WorkspaceEmptyState: View {
    var face = PerryCharacterPose.Face.asleep
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            PerryCharacterView(pose: { var pose = PerryCharacterPose(); pose.face = face; return pose }(), size: 34)
                .opacity(0.9)
                .padding(.bottom, 4)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(.title2, design: .serif, weight: .semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(PerryTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(InkButtonStyle())
                    .controlSize(.small)
                    .padding(.top, 8)
            }
        }
        .accessibilityElement(children: .contain)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
