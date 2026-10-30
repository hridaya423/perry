import AppKit
import PerryOverlay

class PerryPanel: NSPanel {
    private let keyable: Bool

    init(
        frame: NSRect = .zero,
        level: NSWindow.Level = .statusBar,
        canBecomeKey: Bool = false,
        hasShadow: Bool = false,
        extraStyle: NSWindow.StyleMask = []
    ) {
        keyable = canBecomeKey
        super.init(
            contentRect: frame,
            styleMask: NSWindow.StyleMask([.borderless, .nonactivatingPanel]).union(extraStyle),
            backing: .buffered,
            defer: false
        )
        self.level = level
        self.hasShadow = hasShadow
        isOpaque = false
        backgroundColor = .clear
        appearance = NSAppearance(named: .darkAqua)
        PerryWindowChrome.applyChrome(to: self)
    }

    override var canBecomeKey: Bool { keyable }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
