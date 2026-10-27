import AppKit

enum NotchLayout {
    enum Mode: Equatable {
        case peek(content: CGFloat?)
        case focused(content: CGFloat?)
        case onboarding(content: CGFloat?)
        case workspace
    }

    struct Metrics: Equatable {
        var cameraInset: CGFloat
        var screen: CGSize
        var closed: CGSize

        @MainActor
        init(_ screen: NSScreen?) {
            cameraInset = max(24, screen?.safeAreaInsets.top ?? 0)
            self.screen = screen?.frame.size ?? .zero
            if let screen, screen.safeAreaInsets.top > 0,
               let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                closed = CGSize(width: right.minX - left.maxX + NotchShape.closed.topRadius * 2, height: screen.safeAreaInsets.top)
            } else {
                closed = screen.map { NotchPresence.zoneRect(for: $0).size } ?? CGSize(width: 120, height: 24)
            }
        }
    }

    static let shadowPadding: CGFloat = 48
    static let topInset: CGFloat = 12
    static let bottomInset: CGFloat = 16
    static let contentInset: CGFloat = 18
    static let peekInset: CGFloat = 24
    static let peekWidth: CGFloat = 480
    static let interactionBar: CGFloat = 30
    static let onboardingWidth: CGFloat = 560

    @MainActor
    static func mode(_ presentation: NotchPresentation, expansion: NotchExpansion, showsPeek: Bool) -> Mode {
        if presentation.showsInteraction, let entry = presentation.current,
           !(showsPeek && entry.priority == .activity) {
            return .focused(content: entry.contentHeight)
        }
        if let height = expansion.onboardingHeight { return .onboarding(content: height) }
        return showsPeek ? .peek(content: expansion.peekHeight) : .workspace
    }

    static func cap(screen: CGSize) -> CGSize {
        CGSize(width: min(800, screen.width - 64), height: min(screen.height * 0.62, 540))
    }

    static func size(_ mode: Mode, cameraInset: CGFloat, screen: CGSize) -> CGSize {
        let cap = cap(screen: screen)
        let width: CGFloat, height: CGFloat
        switch mode {
        case .peek(let content):
            width = peekWidth
            height = content.map { min(max(cameraInset + topInset + $0 + bottomInset, 120), 440) } ?? 320
        case .focused(let content):
            width = 440
            height = content.map { min(max(cameraInset + interactionBar + $0 + bottomInset, 120), 340) } ?? 340
        case .onboarding(let content):
            width = onboardingWidth
            height = content.map { max(cameraInset + $0 + bottomInset, 120) } ?? 520
        case .workspace:
            width = 780
            height = 520
        }
        return CGSize(width: min(width, cap.width), height: min(height, cap.height))
    }

    static func windowFrame(screen: CGRect, centerX: CGFloat) -> CGRect {
        let cap = cap(screen: screen.size)
        return NotchPresence.notchPanelFrame(
            size: CGSize(width: cap.width + shadowPadding * 2, height: cap.height + shadowPadding),
            screenFrame: screen,
            centerX: centerX
        )
    }

    static func visibleFrame(_ size: CGSize, in window: CGRect) -> CGRect {
        CGRect(x: window.midX - size.width / 2, y: window.maxY - size.height, width: size.width, height: size.height)
    }
}
