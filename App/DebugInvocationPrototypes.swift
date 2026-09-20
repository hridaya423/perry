#if DEBUG
import AppKit
import SwiftUI

/// Throwaway invocation-arrangement prototypes for Phase 2 design selection.
/// Compared against: one focal action, mode clarity, target visibility,
/// keyboard completion, compact-window behavior. Open via
/// `--perry-debug-surface prototypes` or the DEBUG State fixtures menu.
/// Nothing here ships; the winning shape is reimplemented in Phase 7.
enum DebugInvocationPrototype: String, CaseIterable, Identifiable {
    case segmented
    case modeless
    case inlineMode

    var id: String { rawValue }
    var title: String {
        switch self {
        case .segmented: return "A · Segmented Guide/Do + Start"
        case .modeless: return "B · Modeless field + Start"
        case .inlineMode: return "C · Field + inline mode toggle"
        }
    }
}

final class DebugPrototypeWindow: NSWindow {
    static func show() {
        let window = DebugPrototypeWindow()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        title = "Perry invocation prototypes"
        contentView = NSHostingView(rootView: DebugPrototypeGallery())
    }
}

struct DebugPrototypeGallery: View {
    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            ForEach(DebugInvocationPrototype.allCases) { prototype in
                VStack(alignment: .leading, spacing: 12) {
                    Text(prototype.title)
                        .font(PerryTheme.Typography.panelSubtitle)
                        .foregroundStyle(PerryTheme.Colors.textSecondary)
                    PrototypeShell { content(for: prototype) }
                }
                .frame(width: 360)
            }
        }
        .padding(24)
        .background(PerryTheme.Colors.canvas)
    }

    @ViewBuilder
    private func content(for prototype: DebugInvocationPrototype) -> some View {
        switch prototype {
        case .segmented: SegmentedPrototype()
        case .modeless: ModelessPrototype()
        case .inlineMode: InlineModePrototype()
        }
    }
}

private struct PrototypeShell<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: PerryTheme.Spacing.section) {
            content
        }
        .padding(PerryTheme.Spacing.panelInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PerryTheme.Colors.surface, in: RoundedRectangle(cornerRadius: PerryTheme.Radius.panel))
    }
}

private struct PrototypeStatus: View {
    let text: String
    var body: some View {
        HStack(spacing: PerryTheme.Spacing.control) {
            Circle()
                .fill(PerryTheme.Colors.textSecondary)
                .frame(width: PerryTheme.Sizing.statusDot, height: PerryTheme.Sizing.statusDot)
            Text(text)
                .font(PerryTheme.Typography.panelMetadata)
                .foregroundStyle(PerryTheme.Colors.text)
            Spacer()
        }
    }
}

/// A — the locked spec: segmented Guide/Do, one field, one Start.
private struct SegmentedPrototype: View {
    @State private var mode = 0
    @State private var text = ""
    @State private var background = false
    @FocusState private var focused: Bool

    var body: some View {
        Picker("Mode", selection: $mode) {
            Text("Guide").tag(0)
            Text("Do").tag(1)
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Guide or Do")

        TextField(mode == 0 ? "What should Perry show you?" : "What should Perry take off your hands?", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(PerryTheme.Typography.panelBody)
            .focused($focused)
            .accessibilityLabel("Task request")

        if mode == 1 {
            Toggle("Run in background", isOn: $background)
                .controlSize(.small)
        }

        PrototypeStatus(text: "Press ⌥⌘P when you want Perry.")

        Button(mode == 0 ? "Start guiding" : "Start") {}
            .buttonStyle(.borderedProminent)
            .tint(PerryTheme.Colors.accent)
            .frame(maxWidth: .infinity)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .onAppear { focused = true }
    }
}

/// B — no visible mode: intent parsed from the field, hint chips below.
private struct ModelessPrototype: View {
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Teach me, or take it off my hands…", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(PerryTheme.Typography.panelBody)
            .focused($focused)
            .accessibilityLabel("Task request")

        HStack(spacing: PerryTheme.Spacing.control) {
            Text("Guide")
                .font(PerryTheme.Typography.panelMetadata)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(PerryTheme.Colors.canvas, in: Capsule())
            Text("Do")
                .font(PerryTheme.Typography.panelMetadata)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(PerryTheme.Colors.accent.opacity(0.25), in: Capsule())
            Spacer()
        }

        PrototypeStatus(text: "Sounds like a task — Perry will do it.")

        Button("Start") {}
            .buttonStyle(.borderedProminent)
            .tint(PerryTheme.Colors.accent)
            .frame(maxWidth: .infinity)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .onAppear { focused = true }
    }
}

/// C — field + Start row, mode as a quiet inline toggle beneath.
private struct InlineModePrototype: View {
    @State private var mode = 0
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: PerryTheme.Spacing.inline) {
            TextField("What are we doing?", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(PerryTheme.Typography.panelBody)
                .focused($focused)
                .accessibilityLabel("Task request")
            Button("Start") {}
                .buttonStyle(.borderedProminent)
                .tint(PerryTheme.Colors.accent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }

        HStack(spacing: PerryTheme.Spacing.control) {
            Button("Guide") { mode = 0 }
                .buttonStyle(.plain)
                .font(PerryTheme.Typography.panelMetadata.weight(mode == 0 ? .semibold : .regular))
                .foregroundStyle(mode == 0 ? PerryTheme.Colors.accent : PerryTheme.Colors.textSecondary)
            Text("·").foregroundStyle(PerryTheme.Colors.textSecondary)
            Button("Do") { mode = 1 }
                .buttonStyle(.plain)
                .font(PerryTheme.Typography.panelMetadata.weight(mode == 1 ? .semibold : .regular))
                .foregroundStyle(mode == 1 ? PerryTheme.Colors.accent : PerryTheme.Colors.textSecondary)
            Spacer()
        }

        PrototypeStatus(text: mode == 0 ? "I'll point; you click." : "I'll work; you supervise.")
    }
}
#endif
