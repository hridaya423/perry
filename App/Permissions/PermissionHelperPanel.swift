import AppKit
import SwiftUI

final class PermissionHelperPanel: NSPanel {
    static let cardSize = CGSize(width: 420, height: 150)

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.cardSize),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    func show<Content: View>(_ content: Content) {
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        contentView = host
        invalidateShadow()
    }

    func flyIn(from source: NSRect, to target: NSRect, reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
        if reduceMotion {
            setFrame(target, display: true)
        } else {
            let start = NSRect(
                x: source.midX - target.width * 0.3,
                y: source.midY - target.height * 0.3,
                width: target.width * 0.6,
                height: target.height * 0.6
            )
            setFrame(start, display: true)
        }
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.18 : 0.42
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.1, 1)
            animator().alphaValue = 1
            if !reduceMotion { animator().setFrame(target, display: true) }
        }
    }

    func follow(_ target: NSRect) {
        setFrame(target, display: true)
    }

    func setDragging(_ dragging: Bool) {
        ignoresMouseEvents = dragging
        alphaValue = dragging ? 0.72 : 1
    }

    func fadeOut(then completion: @escaping () -> Void = {}) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.orderOut(nil)
            completion()
        }
    }
}

struct PermissionHelperView: View {
    enum Phase: Equatable {
        case instruction
        case retry
        case settingsClosed
        case wrongLocation
        case restart
        case granted
    }

    struct Actions {
        var dragBegan: () -> Void = {}
        var dragEnded: (Bool) -> Void = { _ in }
        var reopenSettings: () -> Void = {}
        var restart: () -> Void = {}
        var close: () -> Void = {}
    }

    let pane: PrivacyPane
    let appURL: URL
    var phase: Phase
    var actions = Actions()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var nudged = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                lead
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(PerryTheme.Scale.title)
                        .foregroundStyle(PerryTheme.Colors.text)
                    if let detail {
                        detail
                            .font(PerryTheme.Scale.secondary)
                            .foregroundStyle(PerryTheme.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                if phase != .granted {
                    WindowControlButton(systemImage: "xmark", label: "Close", action: actions.close)
                        .padding(.top, -4)
                        .padding(.trailing, -4)
                }
            }
            switch phase {
            case .instruction, .retry:
                AppBundleDragRow(appURL: appURL, onDragBegan: actions.dragBegan, onDragEnded: actions.dragEnded)
                    .frame(height: 52)
                HStack {
                    Text("macOS will ask for your password.")
                    Spacer(minLength: 8)
                    Button("Reopen list", action: actions.reopenSettings)
                        .buttonStyle(.pressable)
                        .foregroundStyle(PerryTheme.Colors.textSecondary)
                        .help("Open the \(pane.displayName()) list again")
                }
                .font(PerryTheme.Scale.meta)
                .foregroundStyle(PerryTheme.Colors.textSecondary)
            case .settingsClosed:
                Button("Open System Settings", action: actions.reopenSettings)
                    .buttonStyle(InkButtonStyle(.primary))
                    .controlSize(.small)
                    .padding(.leading, 32)
            case .restart:
                Button("Restart Perry", action: actions.restart)
                    .buttonStyle(InkButtonStyle(.primary))
                    .controlSize(.small)
                    .padding(.leading, 32)
            case .wrongLocation, .granted:
                EmptyView()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(PerryTheme.Colors.crown, in: RoundedRectangle(cornerRadius: PerryTheme.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PerryTheme.Radius.panel, style: .continuous)
                .strokeBorder(.white.opacity(0.1), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .environment(\.colorScheme, .dark)
        .onAppear { if !reduceMotion { nudged = true } }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var lead: some View {
        switch phase {
        case .instruction:
            LeadDisc(systemImage: "arrow.up", tint: PerryTheme.Colors.accent, nudge: nudged ? -3 : 0)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: nudged)
        case .retry, .settingsClosed, .wrongLocation:
            LeadDisc(systemImage: "exclamationmark", tint: PerryTheme.Colors.caution)
        case .restart:
            LeadDisc(systemImage: "arrow.clockwise", tint: PerryTheme.Colors.caution)
        case .granted:
            LeadDisc(systemImage: "checkmark", tint: PerryTheme.Colors.success)
        }
    }

    private var title: String {
        switch phase {
        case .instruction: "Turn on Perry in the list above."
        case .retry: "Perry isn’t in the list yet."
        case .settingsClosed: "Reopen System Settings."
        case .wrongLocation: "Move Perry to Applications first."
        case .restart: "Restart Perry to finish."
        case .granted: "Perry has access."
        }
    }

    private var detail: Text? {
        let name = Text(pane.displayName().replacingOccurrences(of: " ", with: "\u{00A0}")).foregroundStyle(PerryTheme.Colors.text)
        return switch phase {
        case .instruction: Text("Not there? Drag me in.")
        case .retry: Text("Drag Perry in again.")
        case .settingsClosed: Text("Then turn on Perry in \(name).")
        case .wrongLocation: Text("Then open it from there and try again.")
        case .restart: Text("Choose \(Text("Quit & Reopen").foregroundStyle(PerryTheme.Colors.text)) if macOS asks, or restart here.")
        case .granted: nil
        }
    }
}
