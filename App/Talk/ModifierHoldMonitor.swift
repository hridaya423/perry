import AppKit

/// Talk's entry gesture: hold ⌃⌥ to talk, double-tap ⌃ for the typed composer
/// (both are saved gestures; these are the defaults).
/// The tap listens for keyDown as well as flagsChanged: a key pressed during
/// a hold means a chorded shortcut (⌃⌥←, ⌃⌥⌘V…) — the hold cancels instead of
/// submitting, and ⌃ chords typed normally (⌃A, ⌃E, ⌃C, ⌃V) can never fake a
/// double-tap. The hold only commits after `commitDelay` with no key pressed:
/// the listening cue is instant, but nothing heavy starts for a stray chord.
/// A listen-only event tap — same shape as PushToTalkController, which stays
/// for the ⌥⌘Space dictation path.
enum TalkGesture {
    static var keys: String { PerryPreferences.talkGesture.keys }
    static var talk: String { "\(PerryPreferences.talkGesture.spoken) to talk" }
    static var steer: String { "\(PerryPreferences.talkGesture.spoken) to steer" }
    static var type: String { "\(PerryPreferences.typeGesture.spoken) to type" }
}

@MainActor
final class ModifierHoldMonitor {
    static let eventTapMask =
        (CGEventMask(1) &<< CGEventType.flagsChanged.rawValue)
        | (CGEventMask(1) &<< CGEventType.keyDown.rawValue)
        | (CGEventMask(1) &<< CGEventType.tapDisabledByTimeout.rawValue)
        | (CGEventMask(1) &<< CGEventType.tapDisabledByUserInput.rawValue)

    private let commitDelay: TimeInterval
    private let talkHold: () -> ModifierSet
    private let typeTap: () -> ModifierSet
    private let onHoldStart: () -> Void
    private let onHoldCommit: () -> Void
    private let onHoldEnd: () -> Void
    private let onHoldCancel: () -> Void
    private let onHoldTap: () -> Void
    private let onComposer: () -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fallbackGlobalMonitors: [Any] = []
    private var fallbackLocalMonitors: [Any] = []
    private var tapRetry: Timer?

    private var holding = false
    private var swallowing = false
    private(set) var captureMode: PushToTalkController.CaptureMode?
    var interceptHold: () -> Bool = { false }
    private var holdStartedAt: TimeInterval = 0
    private var committed = false
    private var commitTask: Task<Void, Never>?
    private var typeDown = false
    private var typePressClean = true
    private var typePressAt: TimeInterval = 0
    private var lastCleanTypeRelease: TimeInterval?
    private let doubleTapWindow: TimeInterval = 0.35
    private let tapMaxDuration: TimeInterval = 0.25

    init(
        commitDelay: TimeInterval = 0.12,
        talkHold: @escaping () -> ModifierSet = { PerryPreferences.talkGesture.holdModifiers ?? [.control, .option] },
        typeTap: @escaping () -> ModifierSet = { PerryPreferences.typeGesture.doubleTapModifiers ?? [.control] },
        onHoldStart: @escaping () -> Void,
        onHoldCommit: @escaping () -> Void,
        onHoldEnd: @escaping () -> Void,
        onHoldCancel: @escaping () -> Void,
        onHoldTap: @escaping () -> Void,
        onComposer: @escaping () -> Void
    ) {
        self.commitDelay = commitDelay
        self.talkHold = talkHold
        self.typeTap = typeTap
        self.onHoldStart = onHoldStart
        self.onHoldCommit = onHoldCommit
        self.onHoldEnd = onHoldEnd
        self.onHoldCancel = onHoldCancel
        self.onHoldTap = onHoldTap
        self.onComposer = onComposer
    }

    func start() {
        guard eventTap == nil, fallbackGlobalMonitors.isEmpty else { return }
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: Self.eventTapMask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<ModifierHoldMonitor>.fromOpaque(refcon).takeUnretainedValue()
                // Read our own clock rather than CGEvent.timestamp — its unit
                // is not guaranteed across releases, and this clock matches
                // the NSEvent.timestamp used by the fallback monitors.
                let timestamp = ProcessInfo.processInfo.systemUptime
                Task { @MainActor [weak monitor] in
                    guard let monitor else { return }
                    switch type {
                    case .keyDown:
                        monitor.handleKeyDown(keyCode: event.getIntegerValueField(.keyboardEventKeycode))
                    case .flagsChanged:
                        monitor.handle(
                            timestamp: timestamp,
                            modifiers: ModifierSet(event.flags),
                            isFlagsChanged: true,
                            tapDisabled: false
                        )
                    case .tapDisabledByTimeout, .tapDisabledByUserInput:
                        monitor.handle(
                            timestamp: timestamp,
                            modifiers: [],
                            isFlagsChanged: false,
                            tapDisabled: true
                        )
                    default:
                        break
                    }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        if let eventTap {
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
            if let runLoopSource {
                CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            }
            captureMode = .eventTap
            return
        }
        installFallbackMonitors()
        captureMode = .fallbackMonitors
        tapRetry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.retryEventTap() }
        }
    }

    private func retryEventTap() {
        guard captureMode == .fallbackMonitors, CGPreflightListenEventAccess() || AXIsProcessTrusted() else { return }
        stop()
        start()
    }

    func stop() {
        tapRetry?.invalidate()
        tapRetry = nil
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
        runLoopSource = nil
        eventTap = nil
        for monitor in fallbackGlobalMonitors { NSEvent.removeMonitor(monitor) }
        for monitor in fallbackLocalMonitors { NSEvent.removeMonitor(monitor) }
        fallbackGlobalMonitors = []
        fallbackLocalMonitors = []
        captureMode = nil
        resetCaptureState()
    }

    private func installFallbackMonitors() {
        let flagsChanged: (NSEvent) -> Void = { [weak self] event in
            self?.handle(
                timestamp: event.timestamp,
                modifiers: ModifierSet(event.modifierFlags),
                isFlagsChanged: true,
                tapDisabled: false
            )
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flagsChanged) {
            fallbackGlobalMonitors.append(monitor)
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            self?.handleKeyDown(keyCode: Int64(event.keyCode))
        }) {
            fallbackGlobalMonitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            if event.type == .keyDown {
                self?.handleKeyDown(keyCode: Int64(event.keyCode))
            } else {
                flagsChanged(event)
            }
            return event
        } {
            fallbackLocalMonitors.append(monitor)
        }
    }

    func handle(timestamp: TimeInterval, control: Bool, option: Bool, isFlagsChanged: Bool, tapDisabled: Bool) {
        var modifiers: ModifierSet = []
        if control { modifiers.insert(.control) }
        if option { modifiers.insert(.option) }
        handle(timestamp: timestamp, modifiers: modifiers, isFlagsChanged: isFlagsChanged, tapDisabled: tapDisabled)
    }

    func handle(timestamp: TimeInterval, modifiers: ModifierSet, isFlagsChanged: Bool, tapDisabled: Bool) {
        let typeSet = typeTap()
        let typeHeld = modifiers.isSuperset(of: typeSet)
        if tapDisabled {
            resetCaptureState()
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }
        guard isFlagsChanged else { return }

        if swallowing {
            if !modifiers.isSuperset(of: talkHold()) {
                swallowing = false
                holding = false
            }
        } else if modifiers == talkHold() {
            lastCleanTypeRelease = nil
            if !holding, interceptHold() {
                holding = true
                swallowing = true
            } else if !holding {
                holding = true
                holdStartedAt = timestamp
                committed = false
                PerfMark.mark("talk.keydown")
                onHoldStart()
                if commitDelay <= 0 {
                    committed = true
                    onHoldCommit()
                } else {
                    commitTask = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: UInt64(commitDelay * 1_000_000_000))
                        guard let self, !Task.isCancelled, self.holding, !self.committed else { return }
                        self.committed = true
                        self.onHoldCommit()
                    }
                }
            }
        } else if holding, modifiers.isStrictSuperset(of: talkHold()) {
            handleKeyDown()
        } else if holding {
            holding = false
            commitTask?.cancel()
            commitTask = nil
            let wasCommitted = committed
            committed = false
            if timestamp - holdStartedAt < tapMaxDuration {
                PerfMark.mark("talk.tap")
                onHoldTap()
            } else if wasCommitted {
                PerfMark.mark("talk.keyup")
                onHoldEnd()
            } else {
                // Released before commit (or a chord already killed it): the
                // hold never became a real utterance — discard, don't submit.
                PerfMark.mark("talk.cancel.release_early")
                onHoldCancel()
            }
        }

        if typeHeld && !typeDown {
            typePressClean = modifiers == typeSet
            typePressAt = timestamp
            if typePressClean, let last = lastCleanTypeRelease, timestamp - last <= doubleTapWindow {
                lastCleanTypeRelease = nil
                PerfMark.mark("composer.open")
                onComposer()
            }
        }
        if !typeHeld && typeDown, modifiers.isSubset(of: typeSet), typePressClean,
           timestamp - typePressAt <= tapMaxDuration {
            lastCleanTypeRelease = timestamp
        }
        typeDown = typeHeld
    }

    /// A real key pressed while a modifier gesture is in flight. During a hold
    /// it means a chorded shortcut: cancel without submitting. Otherwise it
    /// just dirties the current ⌃ press and any pending double-tap.
    func handleKeyDown(keyCode: Int64 = -1) {
        lastCleanTypeRelease = nil
        if typeDown { typePressClean = false }
        guard holding, !swallowing else { return }
        holding = false
        committed = false
        commitTask?.cancel()
        commitTask = nil
        PerfMark.markDynamic("talk.cancel.chord.key\(keyCode)")
        onHoldCancel()
    }

    private func resetCaptureState() {
        commitTask?.cancel()
        commitTask = nil
        let wasHolding = holding && !swallowing
        holding = false
        swallowing = false
        committed = false
        typeDown = false
        typePressClean = true
        lastCleanTypeRelease = nil
        if wasHolding {
            PerfMark.mark("talk.cancel.reset")
            onHoldCancel()
        }
    }
}
