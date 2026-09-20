import AppKit
import PerryGuide

/// Bounded Watch & Learn capture. While armed it listens for the user's own
/// clicks and keypresses and correlates each click with the AX element under
/// it via a fresh observation. Text aimed at secure or unknown-sensitivity
/// fields is dropped before it can ever reach a routine. Capped at
/// `maximumEvents` so a demonstration stays bounded; the caller stops it.
@MainActor
final class DemonstrationRecorder {
    static let maximumEvents = 60

    private let observe: () async throws -> GuideObservation
    private let bundleIDProvider: () -> String?
    private let onEventCount: (Int) -> Void
    private var globalMonitors: [Any] = []
    private var localMonitors: [Any] = []
    private var events: [RecordedEvent] = []
    private var bundleID: String?
    private var lastClickTarget: RoutineTarget?
    private var lastClickSensitive = false
    private var recording = false
    private var correlationChain: Task<Void, Never>?

    init(
        observe: @escaping () async throws -> GuideObservation,
        bundleIDProvider: @escaping () -> String?,
        onEventCount: @escaping (Int) -> Void = { _ in }
    ) {
        self.observe = observe
        self.bundleIDProvider = bundleIDProvider
        self.onEventCount = onEventCount
    }

    var isRecording: Bool { recording }
    var eventCount: Int { events.count }

    func start() {
        guard !recording else { return }
        recording = true
        bundleID = bundleIDProvider()
        let mouse: NSEvent.EventTypeMask = [.leftMouseDown]
        let keys: NSEvent.EventTypeMask = [.keyDown]
        globalMonitors = [
            NSEvent.addGlobalMonitorForEvents(matching: mouse) { [weak self] event in
                self?.handleMouse(event)
            },
            NSEvent.addGlobalMonitorForEvents(matching: keys) { [weak self] event in
                self?.handleKey(event)
            }
        ].compactMap { $0 }
        localMonitors = [
            NSEvent.addLocalMonitorForEvents(matching: mouse) { [weak self] event in
                self?.handleMouse(event)
                return event
            },
            NSEvent.addLocalMonitorForEvents(matching: keys) { [weak self] event in
                self?.handleKey(event)
                return event
            }
        ].compactMap { $0 }
    }

    /// Stops listening and waits for in-flight click correlations to land so
    /// the returned demonstration reflects every click the user made.
    func stop() async -> RecordedDemonstration? {
        guard recording else { return nil }
        recording = false
        globalMonitors.forEach { NSEvent.removeMonitor($0) }
        localMonitors.forEach { NSEvent.removeMonitor($0) }
        globalMonitors = []
        localMonitors = []
        _ = await correlationChain?.value
        guard !events.isEmpty, let bundleID else { return nil }
        return RecordedDemonstration(bundleID: bundleID, events: events)
    }

    private func handleMouse(_ event: NSEvent) {
        guard recording, events.count < Self.maximumEvents else { return }
        let cgPoint = event.cgEvent?.location ?? CGPoint(x: event.locationInWindow.x, y: event.locationInWindow.y)
        let axPoint = CGPointShim(x: Double(cgPoint.x), y: Double(cgPoint.y))
        // Correlations resolve in click order against fresh observations.
        correlationChain = Task { @MainActor [weak self] in
            _ = await self?.correlationChain?.value
            await self?.recordClick(axPoint: axPoint)
        }
    }

    /// Click correlation, split out so tests drive it without NSEvent
    /// monitors: resolve the AX point against a fresh observation and record
    /// the element anchor. Clicks that hit nothing actionable are dropped.
    func recordClick(axPoint: CGPointShim) async {
        guard recording, let observation = try? await observe() else { return }
        guard let element = element(at: axPoint, in: observation.snapshot.elements) else { return }
        lastClickTarget = RoutineTarget(role: element.role.rawValue, label: element.label, subrole: element.subrole)
        // Secure or unknown-sensitivity fields keep their click but typing
        // into them is dropped — a routine must never hold a secret.
        lastClickSensitive = element.sensitivity != .ordinary
        append(.click(lastClickTarget!))
    }

    private func handleKey(_ event: NSEvent) {
        guard recording, events.count < Self.maximumEvents else { return }
        recordKey(characters: event.characters, keyCode: event.keyCode, modifiers: event.modifierFlags)
    }

    /// Event classification, split out so tests drive it without NSEvent
    /// monitors: plain characters append typed text onto the last clicked
    /// target; named keys and modifier chords record a key press.
    func recordKey(characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        if let name = Self.namedKey(keyCode: keyCode) {
            append(.keyPress(name))
            return
        }
        guard let characters, !characters.isEmpty,
              modifiers.intersection([.command, .control, .option, .function]).isEmpty else { return }
        guard !lastClickSensitive else { return }
        append(.typed(text: characters, into: lastClickTarget))
    }

    private func append(_ event: RecordedEvent) {
        events.append(event)
        onEventCount(events.count)
    }

    /// Smallest actionable element enclosing the click, in AX coordinates.
    private func element(at point: CGPointShim, in elements: [AXElement]) -> AXElement? {
        elements
            .filter { element in
                let frame = element.frame
                return element.isActionable
                    && point.x >= frame.x && point.x <= frame.x + frame.width
                    && point.y >= frame.y && point.y <= frame.y + frame.height
            }
            .min { ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height) }
    }

    private static func namedKey(keyCode: UInt16) -> String? {
        switch keyCode {
        case 36: return "return"
        case 48: return "tab"
        case 53: return "escape"
        case 49: return "space"
        case 51: return "delete"
        case 123: return "left"
        case 124: return "right"
        case 125: return "down"
        case 126: return "up"
        default: return nil
        }
    }
}
