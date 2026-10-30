import AppKit

struct NotchGeometry {
    static let ear: CGFloat = 26
    static let zonePadding: CGFloat = 6

    let screen: NSScreen

    var cameraInset: CGFloat { max(24, screen.safeAreaInsets.top) }

    var housing: CGSize? {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return nil }
        return CGSize(width: right.minX - left.maxX, height: screen.safeAreaInsets.top)
    }

    var zone: CGRect {
        let top = screen.frame.maxY
        if screen.safeAreaInsets.top > 0 {
            let left = screen.auxiliaryTopLeftArea?.maxX ?? screen.frame.midX - 100
            let right = screen.auxiliaryTopRightArea?.minX ?? screen.frame.midX + 100
            let center = (left + right) / 2
            let width = right - left + (Self.ear + Self.zonePadding) * 2
            return CGRect(x: center - width / 2,
                          y: top - screen.safeAreaInsets.top - Self.zonePadding,
                          width: width,
                          height: screen.safeAreaInsets.top + Self.zonePadding)
        }
        let menuBar = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        return CGRect(x: screen.frame.midX - 60, y: top - menuBar, width: 120, height: menuBar)
    }

    var clickRect: CGRect {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea?.maxX,
              let right = screen.auxiliaryTopRightArea?.minX else { return zone }
        return CGRect(x: left - Self.ear, y: screen.frame.maxY - screen.safeAreaInsets.top,
                      width: right - left + Self.ear * 2, height: screen.safeAreaInsets.top)
    }

    var centerX: CGFloat { zone.midX }

    static func panelFrame(size: CGSize, screenFrame: CGRect, centerX: CGFloat) -> CGRect {
        let width = min(size.width, screenFrame.width)
        let height = min(size.height, screenFrame.height)
        let x = min(max(centerX - width / 2, screenFrame.minX), screenFrame.maxX - width)
        return CGRect(x: x, y: screenFrame.maxY - height, width: width, height: height)
    }

    @MainActor
    static func screenUnderPointer() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(point) }
            ?? NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            ?? NSScreen.main
    }
}
