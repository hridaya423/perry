import AppKit
import PerryGuide

@MainActor
final class ClickAdvanceObserver {
    private let onClick: (CGPointShim) -> Void
    private var monitors: [Any] = []

    init(onClick: @escaping (CGPointShim) -> Void) {
        self.onClick = onClick
    }

    func start() {
        guard monitors.isEmpty else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
            self?.report(event)
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
            if !(event.window is PerryPanel) { self?.report(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    private func report(_ event: NSEvent) {
        let point = event.cgEvent?.location ?? event.locationInWindow
        onClick(CGPointShim(x: Double(point.x), y: Double(point.y)))
    }
}
