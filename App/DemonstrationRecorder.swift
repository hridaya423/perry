import AppKit
import PerryGuide

@MainActor
final class DemonstrationRecorder {
    static let maximumEvents = 60

    private let observe: () async throws -> GuideObservation
    private let bundleIDProvider: () -> String?
    private let onEventCount: (Int) -> Void
    private let onRecognizedControl: (AXElementFrame) -> Void
    private let onCancelRequested: () -> Void
    private let maximumDuration: Duration
    private let warningLead: Duration
    private let onLimitWarning: () -> Void
    private let onTimeLimit: () -> Void
    private var globalMonitors: [Any] = []
    private var localMonitors: [Any] = []
    private var events: [RecordedEvent] = []
    private var bundleID: String?
    private var lastClickTarget: RoutineTarget?
    private var typingBlocked = false
    private var typingWithheld = false
    private var consecutiveEscapes = 0
    private var recording = false
    private var correlationChain: Task<Void, Never>?
    private var limitTask: Task<Void, Never>?

    init(
        observe: @escaping () async throws -> GuideObservation,
        bundleIDProvider: @escaping () -> String?,
        onEventCount: @escaping (Int) -> Void = { _ in },
        onRecognizedControl: @escaping (AXElementFrame) -> Void = { _ in },
        onCancelRequested: @escaping () -> Void = {},
        maximumDuration: Duration = .seconds(600),
        warningLead: Duration = .seconds(30),
        onLimitWarning: @escaping () -> Void = {},
        onTimeLimit: @escaping () -> Void = {}
    ) {
        self.observe = observe
        self.bundleIDProvider = bundleIDProvider
        self.onEventCount = onEventCount
        self.onRecognizedControl = onRecognizedControl
        self.onCancelRequested = onCancelRequested
        self.maximumDuration = maximumDuration
        self.warningLead = warningLead
        self.onLimitWarning = onLimitWarning
        self.onTimeLimit = onTimeLimit
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
            NSEvent.addLocalMonitorForEvents(matching: keys) { [weak self] event in
                self?.handleKey(event)
                return event
            }
        ].compactMap { $0 }
        limitTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.maximumDuration - self.warningLead)
            guard !Task.isCancelled, self.recording else { return }
            self.onLimitWarning()
            try? await Task.sleep(for: self.warningLead)
            guard !Task.isCancelled, self.recording else { return }
            self.onTimeLimit()
        }
    }

    func stop() async -> RecordedDemonstration? {
        guard recording else { return nil }
        recording = false
        limitTask?.cancel()
        limitTask = nil
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
        consecutiveEscapes = 0
        let cgPoint = event.cgEvent?.location ?? CGPoint(x: event.locationInWindow.x, y: event.locationInWindow.y)
        let axPoint = CGPointShim(x: Double(cgPoint.x), y: Double(cgPoint.y))
        correlationChain = Task { @MainActor [weak self] in
            _ = await self?.correlationChain?.value
            await self?.recordClick(axPoint: axPoint)
        }
    }

    func recordClick(axPoint: CGPointShim) async {
        guard recording else { return }
        guard let observation = try? await observe(),
              let element = element(at: axPoint, in: observation.snapshot.elements) else {
            append(.unrecognizedClick)
            return
        }
        onRecognizedControl(element.frame)
        lastClickTarget = RoutineTarget(role: element.role.rawValue, label: element.label, subrole: element.subrole)
        typingBlocked = element.sensitivity != .ordinary
        typingWithheld = element.sensitivity == .unknown && element.role == .textField
        append(.click(lastClickTarget!))
    }

    private func handleKey(_ event: NSEvent) {
        guard recording, events.count < Self.maximumEvents else { return }
        recordKey(
            characters: event.characters,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            keyCode: event.keyCode,
            modifiers: event.modifierFlags
        )
    }

    func recordKey(
        characters: String?,
        charactersIgnoringModifiers: String? = nil,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) {
        if keyCode == 53, modifiers.intersection([.command, .control, .option, .shift]).isEmpty {
            consecutiveEscapes += 1
            if consecutiveEscapes >= 2 {
                consecutiveEscapes = 0
                onCancelRequested()
                return
            }
        } else {
            consecutiveEscapes = 0
        }
        if !modifiers.intersection([.command, .control, .option]).isEmpty {
            if let key = Self.namedKey(keyCode: keyCode) ?? Self.chordCharacter(charactersIgnoringModifiers ?? characters) {
                append(.chord(key: key, modifiers: Self.modifierNames(modifiers)))
            }
            return
        }
        if let name = Self.namedKey(keyCode: keyCode) {
            append(.keyPress(name))
            if name == "tab" || name == "return" {
                typingBlocked = true
                typingWithheld = false
            }
            return
        }
        guard let characters, !characters.isEmpty,
              modifiers.intersection([.command, .control, .option, .function]).isEmpty else { return }
        guard !typingBlocked else {
            if typingWithheld {
                typingWithheld = false
                append(.typedWithheld(into: lastClickTarget))
            }
            return
        }
        append(.typed(text: characters, into: lastClickTarget))
    }

    private func append(_ event: RecordedEvent) {
        events.append(event)
        onEventCount(events.count)
    }

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

    private static func chordCharacter(_ characters: String?) -> String? {
        guard let character = characters?.lowercased(), character.count == 1,
              character.first?.isLetter == true || character.first?.isNumber == true else { return nil }
        return character
    }

    private static func modifierNames(_ modifiers: NSEvent.ModifierFlags) -> [String] {
        [(NSEvent.ModifierFlags.command, "command"), (.control, "control"), (.option, "option"), (.shift, "shift")]
            .filter { modifiers.contains($0.0) }
            .map(\.1)
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
