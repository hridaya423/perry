#if DEBUG
import AppKit
import SwiftUI
import PerryOverlay

/// Throwaway glass-cursor comparison surface for the Living Pointer design
/// selection. Both candidates (faceted arrow, lens pointer) are drawn across
/// the semantic states and three backgrounds — light, dark, and busy — so
/// legibility and state clarity are judged directly, not guessed. Open via
/// `--perry-debug-surface cursors` or the DEBUG Cursor prototypes menu item.
/// Nothing here ships.
final class DebugCursorGalleryWindow: NSWindow {
    static func show() {
        let window = DebugCursorGalleryWindow()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        title = "Perry cursor prototypes"
        contentView = NSHostingView(rootView: DebugCursorGallery())
    }
}

private struct CursorStateCase: Identifiable {
    let id = UUID()
    let title: String
    let animation: PerryBuddyAnimationState
}

private struct CursorVariantCase: Identifiable {
    let id = UUID()
    let title: String
}

private struct DebugCursorGallery: View {
    private let states: [CursorStateCase] = [
        CursorStateCase(title: "Idle", animation: .idle),
        CursorStateCase(title: "Guiding", animation: .waving),
        CursorStateCase(title: "Acting", animation: .running),
        CursorStateCase(title: "Approval", animation: .waiting),
        CursorStateCase(title: "Thinking", animation: .review),
        CursorStateCase(title: "Done", animation: .jumping),
        CursorStateCase(title: "Blocked", animation: .failed),
    ]

    private let variants = PerryGlassCursorVariant.allCases

    private let morphs = PerryCursorMorph.allCases

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                section(title: "Light", background: Color(white: 0.96), scheme: .light)
                section(title: "Dark", background: Color(white: 0.14), scheme: .dark)
                section(title: "Busy", background: nil, scheme: .dark)
                morphSection(title: "Morphs (light)", background: Color(white: 0.96), scheme: .light)
                morphSection(title: "Morphs (dark)", background: Color(white: 0.14), scheme: .dark)
            }
            .padding(24)
        }
        .frame(minWidth: 1180, minHeight: 560)
    }

    /// Every §5 morph on the section background — snapshot evidence for the
    /// morph grammar (listening shown mid-level so the ring reads).
    @ViewBuilder
    private func morphSection(title: String, background: Color, scheme: ColorScheme) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            HStack(alignment: .top, spacing: 18) {
                ForEach(morphs, id: \.rawValue) { morph in
                    VStack(spacing: 8) {
                        Text(morph.rawValue)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(height: 14)
                        PerryGlassCursorView(
                            size: 44,
                            morph: morph,
                            micLevel: morph == .listening ? 0.7 : 0,
                            sessionActive: morph == .pointer
                        )
                        .frame(width: 64, height: 64)
                    }
                }
            }
            .padding(16)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .environment(\.colorScheme, scheme)
        }
    }

    @ViewBuilder
    private func section(title: String, background: Color?, scheme: ColorScheme) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            HStack(alignment: .top, spacing: 8) {
                ForEach(states) { state in
                    VStack(spacing: 8) {
                        Text(state.title)
                            .font(.caption.weight(.semibold))
                            .frame(height: 14)
                        row(title: "Faceted") {
                            PerryGlassCursorView(animation: state.animation, size: 44, variant: .faceted)
                        }
                        row(title: "Lens") {
                            PerryGlassCursorView(animation: state.animation, size: 44, variant: .lens)
                        }
                    }
                    .frame(width: 148)
                }
            }
            .padding(16)
            .background {
                if let background {
                    background
                } else {
                    busyBackground
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .environment(\.colorScheme, scheme)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Cursor prototypes on \(title.lowercased()) background")
    }

    private func row<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 4) {
            content()
                .frame(width: 48, height: 48)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// Deterministic "busy content" stand-in: stripes plus color blocks so
    /// edge contrast can be judged without needing a real app behind it.
    private var busyBackground: some View {
        ZStack {
            LinearGradient(
                colors: [.white, .gray.opacity(0.7), .white, .black.opacity(0.75)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            HStack(spacing: 0) {
                ForEach(0..<16, id: \.self) { index in
                    (index.isMultiple(of: 2) ? Color.black.opacity(0.25) : Color.white.opacity(0.3))
                        .frame(width: 12)
                }
            }
        }
    }
}
#endif
