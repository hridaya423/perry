import AppKit

/// Talk's entry gesture: hold ⌃⌥ to talk, double-tap ⌃ for the typed composer.
/// The tap listens for keyDown as well as flagsChanged: a key pressed during
/// a hold means a chorded shortcut (⌃⌥←, ⌃⌥⌘V…) — the hold cancels instead of
/// submitting, and ⌃ chords typed normally (⌃A, ⌃E, ⌃C, ⌃V) can never fake a
/// double-tap. The hold only commits after `commitDelay` with no key pressed:
/// the listening cue is instant, but nothing heavy starts for a stray chord.
/// A listen-only event tap — same shape as PushToTalkController, which stays
/// for the ⌥⌘Space dictation path.
@MainActor
final class ModifierHoldMonitor {
    static let eventTapMask =
        (CGEventMask(1) &<< CGEventType.flagsChanged.rawValue)
        | (CGEventMask(1) &<< CGEventType.keyDown.rawValue)
        | (CGEventMask(1) &<< CGEventType.tapDisabledByTimeout.rawValue)
        | (CGEventMask(1) &<< CGEventType.tapDisabledByUserInput.rawValue)

    private let commitDelay: TimeInterval
    private let onHoldStart: () -> Void
    private let onHoldCommit: () -> Void
    private let onHoldEnd: () -> Void
    private let onHoldCancel: () -> Void
    private let onComposer: () -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fallbackGlobalMonitors: [Any] = []
    private var fallbackLocalMonitors: [Any] = []

    private var holding = false
    private var committed = false
    private var commitTask: Task<Void, Never>?
    private var controlDown = false
    private var controlPressClean = true
    private var controlPressAt: TimeInterval = 0
    private var lastCleanControlRelease: TimeInterval?
    private let doubleTapWindow: TimeInterval = 0.35
    private let tapMaxDuration: TimeInterval = 0.25

    init(
        commitDelay: TimeInterval = 0.12,
        onHoldStart: @escaping () -> Void,
        onHoldCommit: @escaping () -> Void,
        onHoldEnd: @escaping () -> Void,
        onHoldCancel: @escaping () -> Void,
        onComposer: @escaping () -> Void
    ) {
        self.commitDelay = commitDelay
        self.onHoldStart = onHoldStart
        self.onHoldCommit = onHoldCommit
        self.onHoldEnd = onHoldEnd
        self.onHoldCancel = onHoldCancel
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
                        monitor.handleKeyDown()
                    case .flagsChanged:
                        let flags = event.flags
                        monitor.handle(
                            timestamp: timestamp,
                            control: flags.contains(.maskControl),
                            option: flags.contains(.maskAlternate),
                            isFlagsChanged: true,
                            tapDisabled: false
                        )
                    case .tapDisabledByTimeout, .tapDisabledByUserInput:
                        monitor.handle(
                            timestamp: timestamp,
                            control: false,
                            option: false,
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
            return
        }
        installFallbackMonitors()
    }

    func stop() {
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
        resetCaptureState()
    }

    private func installFallbackMonitors() {
        let flagsChanged: (NSEvent) -> Void = { [weak self] event in
            self?.handle(
                timestamp: event.timestamp,
                control: event.modifierFlags.contains(.control),
                option: event.modifierFlags.contains(.option),
                isFlagsChanged: true,
                tapDisabled: false
            )
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flagsChanged) {
            fallbackGlobalMonitors.append(monitor)
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] _ in
            self?.handleKeyDown()
        }) {
            fallbackGlobalMonitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            if event.type == .keyDown {
                self?.handleKeyDown()
            } else {
                flagsChanged(event)
            }
            return event
        } {
            fallbackLocalMonitors.append(monitor)
        }
    }

    func handle(timestamp: TimeInterval, control: Bool, option: Bool, isFlagsChanged: Bool, tapDisabled: Bool) {
        if tapDisabled {
            resetCaptureState()
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }
        guard isFlagsChanged else { return }

        if control && option {
            lastCleanControlRelease = nil
            if !holding {
                holding = true
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
        } else if holding {
            holding = false
            commitTask?.cancel()
            commitTask = nil
            if committed {
                committed = false
                PerfMark.mark("talk.keyup")
                onHoldEnd()
            } else {
                // Released before commit (or a chord already killed it): the
                // hold never became a real utterance — discard, don't submit.
                PerfMark.mark("talk.cancel")
                onHoldCancel()
            }
        }

        if control && !controlDown {
            controlPressClean = true
            controlPressAt = timestamp
            if !option, let last = lastCleanControlRelease, timestamp - last <= doubleTapWindow {
                lastCleanControlRelease = nil
                PerfMark.mark("composer.open")
                onComposer()
            }
        }
        if !control && controlDown, !option, controlPressClean,
           timestamp - controlPressAt <= tapMaxDuration {
            lastCleanControlRelease = timestamp
        }
        controlDown = control
    }

    /// A real key pressed while a modifier gesture is in flight. During a hold
    /// it means a chorded shortcut: cancel without submitting. Otherwise it
    /// just dirties the current ⌃ press and any pending double-tap.
    func handleKeyDown() {
        lastCleanControlRelease = nil
        if controlDown { controlPressClean = false }
        guard holding else { return }
        holding = false
        committed = false
        commitTask?.cancel()
        commitTask = nil
        PerfMark.mark("talk.cancel")
        onHoldCancel()
    }

    private func resetCaptureState() {
        commitTask?.cancel()
        commitTask = nil
        let wasHolding = holding
        holding = false
        committed = false
        controlDown = false
        controlPressClean = true
        lastCleanControlRelease = nil
        if wasHolding {
            PerfMark.mark("talk.cancel")
            onHoldCancel()
        }
    }
}
