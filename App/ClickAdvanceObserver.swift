import AppKit
import PerryGuide

struct ClickLocation: Sendable {
    let axPoint: CGPointShim
    let appKitPoint: CGPointShim
}

@MainActor
final class ClickAdvanceObserver {
    private let onClick: (ClickLocation) -> Void
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(onClick: @escaping (ClickLocation) -> Void) {
        self.onClick = onClick
    }

    func start() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.report(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.report(event)
            return event
        }
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
    }

    private func report(_ event: NSEvent) {
        let cgPoint = event.cgEvent?.location ?? CGPoint(
            x: event.locationInWindow.x,
            y: event.locationInWindow.y
        )
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        onClick(
            ClickLocation(
                axPoint: CGPointShim(x: Double(cgPoint.x), y: Double(cgPoint.y)),
                appKitPoint: CGPointShim(x: Double(cgPoint.x), y: Double(primaryMaxY - cgPoint.y))
            )
        )
    }
}
