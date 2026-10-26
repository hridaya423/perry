import AppKit

@MainActor
final class PushToTalkController {
    static let eventTapMask =
        (CGEventMask(1) &<< CGEventType.keyDown.rawValue)
        | (CGEventMask(1) &<< CGEventType.keyUp.rawValue)
        | (CGEventMask(1) &<< CGEventType.flagsChanged.rawValue)
        | (CGEventMask(1) &<< CGEventType.tapDisabledByTimeout.rawValue)
        | (CGEventMask(1) &<< CGEventType.tapDisabledByUserInput.rawValue)

    /// Which key listener captured the last `start()` — the event tap needs
    /// Input Monitoring access; the NSEvent fallback only sees Perry's own
    /// events, so a missing grant silently leaves the shortcut dead.
    enum CaptureMode {
        case eventTap
        case fallbackMonitors
    }

    private let onPress: () -> Void
    private let onRelease: () -> Void
    private(set) var captureMode: CaptureMode?
    private(set) var gesture: Gesture
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fallbackGlobalMonitor: Any?
    private var fallbackLocalMonitor: Any?
    private var pressed = false
    private var capsKeyDown = false
    private var lastCapsTap: TimeInterval?
    private var lastFlags: CGEventFlags = []
    private var modifierHoldPending = false
    private var modifierHoldChord = false
    private var modifierHoldWorkItem: DispatchWorkItem?

    /// Grace before a ⌃⌥⌘ hold commits — inside the window any real key
    /// means the modifiers were a chord, not a hold.
    private static let modifierHoldGrace: TimeInterval = 0.18

    init(
        gesture: Gesture = PerryPreferences.dictateGesture,
        onPress: @escaping () -> Void,
        onRelease: @escaping () -> Void
    ) {
        self.gesture = gesture
        self.onPress = onPress
        self.onRelease = onRelease
    }

    func update(gesture: Gesture) {
        guard self.gesture != gesture else { return }
        resetCaptureState()
        self.gesture = gesture
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
                let controller = Unmanaged<PushToTalkController>.fromOpaque(refcon).takeUnretainedValue()
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let flags = event.flags
                let isKeyDown = type == .keyDown
                let isKeyUp = type == .keyUp
                let isDisabled = PushToTalkController.tapIsDisabled(type)
                let timestamp = TimeInterval(event.timestamp) / 1_000_000_000
                Task { @MainActor [weak controller] in
                    controller?.handle(keyCode: keyCode, timestamp: timestamp, flags: flags, isKeyDown: isKeyDown, isKeyUp: isKeyUp, tapDisabled: isDisabled)
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
            PerfMark.mark("ptt.capture.eventtap")
            return
        }
        installFallbackMonitors()
    }

    static func tapIsDisabled(_ type: CGEventType) -> Bool {
        type == .tapDisabledByTimeout || type == .tapDisabledByUserInput
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
        captureMode = nil
        resetCaptureState()
    }

    private func installFallbackMonitors() {
        captureMode = .fallbackMonitors
        PerfMark.mark("ptt.capture.fallback")
        let events: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged]
        fallbackGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
            self?.handleFallback(event)
        }
        fallbackLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            self?.handleFallback(event)
            return event
        }
    }

    private func handleFallback(_ event: NSEvent) {
        let keyCode = Int64(event.keyCode)
        handle(
            keyCode: keyCode,
            timestamp: event.timestamp,
            flags: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)),
            isKeyDown: event.type == .keyDown,
            isKeyUp: event.type == .keyUp,
            tapDisabled: false
        )
    }

    func handle(keyCode: Int64, timestamp: TimeInterval, isKeyDown: Bool, isKeyUp: Bool, modifiers: Bool, tapDisabled: Bool) {
        handle(
            keyCode: keyCode,
            timestamp: timestamp,
            flags: modifiers ? [.maskAlternate, .maskCommand] : [],
            isKeyDown: isKeyDown,
            isKeyUp: isKeyUp,
            tapDisabled: tapDisabled
        )
    }

    func handle(keyCode: Int64, timestamp: TimeInterval, flags: CGEventFlags, isKeyDown: Bool, isKeyUp: Bool, tapDisabled: Bool) {
        if tapDisabled {
            resetCaptureState()
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }
        lastFlags = flags
        switch gesture {
        case .chord(let modifiers, let chordKey):
            guard keyCode == Int64(chordKey) else { return }
            if isKeyDown, !pressed, ModifierSet(flags).withoutSide == modifiers.withoutSide {
                pressed = true
                PerfMark.mark("talk.keydown")
                onPress()
            } else if isKeyUp, pressed {
                releaseIfNeeded()
            }
        case .doubleTap(let set) where set == [.capsLock]:
            guard keyCode == 57 else { return }
            if isKeyDown, !capsKeyDown {
                capsKeyDown = true
                if pressed {
                    releaseIfNeeded()
                    lastCapsTap = nil
                } else if let lastCapsTap, timestamp - lastCapsTap <= 0.35 {
                    self.lastCapsTap = nil
                    pressed = true
                    PerfMark.mark("talk.keydown")
                    onPress()
                } else {
                    lastCapsTap = timestamp
                }
            } else if isKeyUp {
                capsKeyDown = false
            }
        case .hold:
            handleModifierHold(flags: flags, isKeyDown: isKeyDown)
        case .doubleTap:
            break
        }
    }

    /// Modifier-hold (fn or ⌃⌥⌘): the modifiers held alone commit after
    /// the grace window; a non-modifier key inside the window means it was
    /// a chord (fn+arrow, ⌃⌥⌘V), not a hold.
    private func handleModifierHold(flags: CGEventFlags, isKeyDown: Bool) {
        if isKeyDown {
            if modifierHoldPending {
                modifierHoldPending = false
                modifierHoldChord = true
                modifierHoldWorkItem?.cancel()
                modifierHoldWorkItem = nil
            }
            return
        }
        if holdModifiersHeld(flags) {
            if pressed || modifierHoldPending { return }
            modifierHoldPending = true
            modifierHoldChord = false
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.modifierHoldWorkItem = nil
                guard self.modifierHoldPending, !self.modifierHoldChord, !self.pressed,
                      self.holdModifiersHeld(self.lastFlags) else { return }
                self.modifierHoldPending = false
                self.pressed = true
                PerfMark.mark("talk.keydown")
                self.onPress()
            }
            modifierHoldWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.modifierHoldGrace, execute: workItem)
        } else {
            modifierHoldPending = false
            modifierHoldChord = false
            modifierHoldWorkItem?.cancel()
            modifierHoldWorkItem = nil
            releaseIfNeeded()
        }
    }

    private func holdModifiersHeld(_ flags: CGEventFlags) -> Bool {
        guard case .hold(let set) = gesture else { return false }
        return ModifierSet(flags) == set
    }

    private func releaseIfNeeded() {
        guard pressed else { return }
        pressed = false
        lastCapsTap = nil
        PerfMark.mark("talk.keyup")
        onRelease()
    }

    private func resetCaptureState() {
        let wasPressed = pressed
        pressed = false
        capsKeyDown = false
        lastCapsTap = nil
        modifierHoldPending = false
        modifierHoldChord = false
        modifierHoldWorkItem?.cancel()
        modifierHoldWorkItem = nil
        if wasPressed {
            onRelease()
        }
    }
}
