import AppKit
import PerryCore
import PerryGuide

struct SpatialSelection: Sendable, Equatable {
    let window: WindowContext?
    let rect: CGRect
    let points: [CGPoint]

    var description: String {
        "x \(Int(rect.minX)), y \(Int(rect.minY)), width \(Int(rect.width)), height \(Int(rect.height))"
    }
}

@MainActor
final class SpatialInputMonitor {
    private let onPointsChanged: ([CGPoint]) -> Void
    private let onSelection: (SpatialSelection) -> Void
    private let onCancel: () -> Void
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var points: [CGPoint] = []
    private var activeWindow: WindowContext?
    private var isDrawing = false

    init(
        onPointsChanged: @escaping ([CGPoint]) -> Void,
        onSelection: @escaping (SpatialSelection) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onPointsChanged = onPointsChanged
        self.onSelection = onSelection
        self.onCancel = onCancel
    }

    func start() {
        guard globalMonitor == nil else { return }
        let events: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        reset()
    }

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53, isDrawing {
            reset()
            PerfMark.mark("spatial.cancel")
            onCancel()
            return
        }

        switch event.type {
        case .leftMouseDown:
            guard isSpatialGesture(event.modifierFlags) else { return }
            isDrawing = true
            points = [screenPoint(for: event)]
            activeWindow = frontmostWindowContext()
            PerfMark.mark("spatial.down")
            onPointsChanged(points)
        case .leftMouseDragged:
            guard isDrawing else { return }
            points.append(screenPoint(for: event))
            if points.count > 240 { points.removeFirst(points.count - 240) }
            onPointsChanged(points)
        case .leftMouseUp:
            guard isDrawing else { return }
            points.append(screenPoint(for: event))
            let selection = makeSelection()
            reset()
            PerfMark.mark(selection == nil ? "spatial.cancel" : "spatial.select")
            if let selection {
                onSelection(selection)
            } else {
                onCancel()
            }
        default:
            break
        }
    }

    private func isSpatialGesture(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection([.option, .command]) == [.option, .command]
    }

    private func screenPoint(for event: NSEvent) -> CGPoint {
        guard let location = event.cgEvent?.location else { return NSEvent.mouseLocation }
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        return CGPoint(x: location.x, y: primaryMaxY - location.y)
    }

    private func makeSelection() -> SpatialSelection? {
        guard points.count >= 4,
              let first = points.first,
              let last = points.last else { return nil }
        let bounds = points.reduce(into: CGRect(x: first.x, y: first.y, width: 0, height: 0)) { result, point in
            result = result.union(CGRect(x: point.x, y: point.y, width: 1, height: 1))
        }
        let closureDistance = hypot(last.x - first.x, last.y - first.y)
        guard bounds.width >= 28, bounds.height >= 28, closureDistance <= max(bounds.width, bounds.height) * 0.45 else {
            return nil
        }
        return SpatialSelection(window: activeWindow, rect: bounds.insetBy(dx: -8, dy: -8), points: points)
    }

    private func frontmostWindowContext() -> WindowContext? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        return WindowContext(
            appBundleID: application.bundleIdentifier ?? "unknown",
            title: application.localizedName ?? "Frontmost window"
        )
    }

    private func reset() {
        points.removeAll(keepingCapacity: true)
        activeWindow = nil
        isDrawing = false
        onPointsChanged([])
    }
}
