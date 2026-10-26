import AppKit

enum NotchLayout {
    enum Mode: Equatable {
        case focused(content: CGFloat?)
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
    static let headerHeight: CGFloat = 28
    static let headerGap: CGFloat = 12
    static let topInset: CGFloat = 6
    static let bottomInset: CGFloat = 16
    static let contentInset: CGFloat = 18

    @MainActor
    static func mode(_ presentation: NotchPresentation) -> Mode {
        guard presentation.showsInteraction, let entry = presentation.current else { return .workspace }
        return .focused(content: entry.contentHeight)
    }

    static func cap(screen: CGSize) -> CGSize {
        CGSize(width: min(600, screen.width * 0.4, screen.width - 32), height: min(screen.height * 0.38, 440))
    }

    static func size(_ mode: Mode, cameraInset: CGFloat, screen: CGSize) -> CGSize {
        let cap = cap(screen: screen)
        let width: CGFloat, height: CGFloat
        switch mode {
        case .focused(let content):
            width = 440
            height = content.map { min(max(cameraInset + topInset + headerHeight + headerGap + $0 + bottomInset, 160), 320) } ?? 320
        case .workspace:
            width = 560
            height = 400
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
