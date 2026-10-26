import AppKit
import SwiftUI

final class AppBundleDragView: NSView, NSDraggingSource {
    var appURL: URL
    var onDragBegan: () -> Void = {}
    var onDragEnded: (Bool) -> Void = { _ in }
    private var mouseDownEvent: NSEvent?

    init(appURL: URL, content: NSView) {
        self.appURL = appURL
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent else { return }
        let start = down.locationInWindow
        let now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) >= 3 else { return }
        mouseDownEvent = nil
        let item = NSDraggingItem(pasteboardWriter: appURL as NSURL)
        item.setDraggingFrame(bounds, contents: snapshot())
        let session = beginDraggingSession(with: [item], event: down, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownEvent = nil
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        onDragBegan()
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDragEnded(!operation.isEmpty)
    }

    private func snapshot() -> NSImage {
        let image = NSImage(size: bounds.size)
        if let bitmap = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: bitmap)
            image.addRepresentation(bitmap)
        }
        return image
    }
}

struct AppBundleDragRow: NSViewRepresentable {
    let appURL: URL
    var onDragBegan: () -> Void = {}
    var onDragEnded: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> AppBundleDragView {
        let content = NSHostingView(rootView: AppBundleRowContent(appURL: appURL))
        let view = AppBundleDragView(appURL: appURL, content: content)
        view.onDragBegan = onDragBegan
        view.onDragEnded = onDragEnded
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel("Perry. Drag into the list in System Settings.")
        return view
    }

    func updateNSView(_ view: AppBundleDragView, context: Context) {
        view.appURL = appURL
        view.onDragBegan = onDragBegan
        view.onDragEnded = onDragEnded
    }
}

private struct AppBundleRowContent: View {
    let appURL: URL

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                .resizable()
                .frame(width: 32, height: 32)
            Text(FileManager.default.displayName(atPath: appURL.path).replacingOccurrences(of: ".app", with: ""))
                .font(PerryTheme.Scale.rowTitle)
                .foregroundStyle(PerryTheme.Colors.text)
            Spacer(minLength: 8)
            Label("Drag", systemImage: "hand.draw")
                .font(PerryTheme.Scale.meta)
                .foregroundStyle(PerryTheme.Colors.textSecondary)
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(PerryTheme.Colors.chip, in: RoundedRectangle(cornerRadius: PerryTheme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PerryTheme.Radius.card, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }
}
