import AppKit
import SwiftUI

final class PermissionHelperPanel: NSPanel {
    static let cardSize = CGSize(width: 360, height: 176)

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
        case restart
        case granted
    }

    let pane: PrivacyPane
    let appURL: URL
    var phase: Phase
    var onDragChange: (Bool) -> Void = { _ in }
    var onRestart: () -> Void = {}
    var onClose: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var nudged = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                lead
                    .frame(width: 22, height: 22)
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
                    WindowControlButton(systemImage: "xmark", label: "Close", action: onClose)
                        .padding(.top, -4)
                        .padding(.trailing, -4)
                }
            }
            switch phase {
            case .instruction:
                AppBundleDragRow(appURL: appURL, onDragChange: onDragChange)
                    .frame(height: 52)
                Text("macOS will ask for your password.")
                    .font(PerryTheme.Scale.meta)
                    .foregroundStyle(PerryTheme.Colors.textTertiary)
            case .restart:
                Button("Restart Perry", action: onRestart)
                    .buttonStyle(InkButtonStyle(.primary))
                    .controlSize(.small)
                    .padding(.leading, 32)
            case .granted:
                EmptyView()
            }
        }
        .padding(16)
        .frame(width: PermissionHelperPanel.cardSize.width, alignment: .topLeading)
        .background(PerryTheme.Colors.crown, in: RoundedRectangle(cornerRadius: PerryTheme.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PerryTheme.Radius.panel, style: .continuous)
                .strokeBorder(.white.opacity(0.1), lineWidth: 1)
        )
        .frame(width: PermissionHelperPanel.cardSize.width, height: PermissionHelperPanel.cardSize.height, alignment: .top)
        .environment(\.colorScheme, .dark)
        .onAppear { if !reduceMotion { nudged = true } }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var lead: some View {
        switch phase {
        case .instruction:
            Image(systemName: "arrow.up")
                .font(PerryTheme.Icon.toolbar)
                .foregroundStyle(PerryTheme.Colors.accent)
                .offset(y: nudged ? -3 : 0)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: nudged)
        case .restart:
            Image(systemName: "arrow.clockwise")
                .font(PerryTheme.Icon.toolbar)
                .foregroundStyle(PerryTheme.Colors.caution)
        case .granted:
            Image(systemName: "checkmark.circle")
                .font(PerryTheme.Icon.toolbar)
                .foregroundStyle(PerryTheme.Colors.success)
        }
    }

    private var title: String {
        switch phase {
        case .instruction: "Drag Perry into the list above."
        case .restart: "Restart Perry to finish."
        case .granted: "Perry has access."
        }
    }

    private var detail: Text? {
        switch phase {
        case .instruction: Text("Then switch it on in \(Text(pane.displayName()).foregroundStyle(PerryTheme.Colors.text)).")
        case .restart: Text("Choose \(Text("Quit & Reopen").foregroundStyle(PerryTheme.Colors.text)) if macOS asks, or restart here.")
        case .granted: nil
        }
    }
}
