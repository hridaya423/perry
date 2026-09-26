import AppKit

/// Talk's entry gesture: hold ⌃⌥ to talk, double-tap ⌃ for the typed composer.
/// A listen-only `flagsChanged` event tap — same shape as PushToTalkController,
/// which stays for the ⌥⌘Space dictation path.
@MainActor
final class ModifierHoldMonitor {
    static let eventTapMask =
        (CGEventMask(1) &<< CGEventType.flagsChanged.rawValue)
        | (CGEventMask(1) &<< CGEventType.tapDisabledByTimeout.rawValue)
        | (CGEventMask(1) &<< CGEventType.tapDisabledByUserInput.rawValue)

    private let onHoldStart: () -> Void
    private let onHoldEnd: () -> Void
    private let onComposer: () -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fallbackGlobalMonitor: Any?
    private var fallbackLocalMonitor: Any?

    private var holding = false
    private var controlDown = false
    private var lastControlTap: TimeInterval?
    private let doubleTapWindow: TimeInterval = 0.35

    init(
        onHoldStart: @escaping () -> Void,
        onHoldEnd: @escaping () -> Void,
        onComposer: @escaping () -> Void
    ) {
        self.onHoldStart = onHoldStart
        self.onHoldEnd = onHoldEnd
        self.onComposer = onComposer
    }

    func start() {
        guard eventTap == nil, fallbackGlobalMonitor == nil else { return }
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: Self.eventTapMask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<ModifierHoldMonitor>.fromOpaque(refcon).takeUnretainedValue()
                let flags = event.flags
                let timestamp = TimeInterval(event.timestamp) / 1_000_000_000
                let isFlagsChanged = type == .flagsChanged
                let isDisabled = type == .tapDisabledByTimeout || type == .tapDisabledByUserInput
                Task { @MainActor [weak monitor] in
                    monitor?.handle(
                        timestamp: timestamp,
                        control: flags.contains(.maskControl),
                        option: flags.contains(.maskAlternate),
                        isFlagsChanged: isFlagsChanged,
                        tapDisabled: isDisabled
                    )
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
        if let fallbackGlobalMonitor { NSEvent.removeMonitor(fallbackGlobalMonitor) }
        if let fallbackLocalMonitor { NSEvent.removeMonitor(fallbackLocalMonitor) }
        fallbackGlobalMonitor = nil
        fallbackLocalMonitor = nil
        resetCaptureState()
    }

    private func installFallbackMonitors() {
        fallbackGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(
                timestamp: event.timestamp,
                control: event.modifierFlags.contains(.control),
                option: event.modifierFlags.contains(.option),
                isFlagsChanged: true,
                tapDisabled: false
            )
        }
        fallbackLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(
                timestamp: event.timestamp,
                control: event.modifierFlags.contains(.control),
                option: event.modifierFlags.contains(.option),
                isFlagsChanged: true,
                tapDisabled: false
            )
            return event
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
            lastControlTap = nil
            if !holding {
                holding = true
                PerfMark.mark("talk.keydown")
                onHoldStart()
            }
        } else if holding {
            holding = false
            PerfMark.mark("talk.keyup")
            onHoldEnd()
        }

        if control && !controlDown && !option {
            // A fresh bare-⌃ press edge: two presses inside the window open the composer.
            if let lastTap = lastControlTap, timestamp - lastTap <= doubleTapWindow {
                lastControlTap = nil
                PerfMark.mark("composer.open")
                onComposer()
            } else {
                lastControlTap = timestamp
            }
        }
        controlDown = control
    }

    private func resetCaptureState() {
        let wasHolding = holding
        holding = false
        controlDown = false
        lastControlTap = nil
        if wasHolding {
            onHoldEnd()
        }
    }
}
