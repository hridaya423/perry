import AppKit

enum PushToTalkShortcut: String, CaseIterable, Identifiable {
    case optionCommandSpace
    case capsLockDoubleTap

    var id: String { rawValue }

    var title: String {
        switch self {
        case .optionCommandSpace: return "Hold ⌥⌘Space"
        case .capsLockDoubleTap: return "Double-tap Caps Lock"
        }
    }

    var detail: String {
        switch self {
        case .optionCommandSpace: return "Hold to talk, release to send"
        case .capsLockDoubleTap: return "Double-tap to start, tap again to stop"
        }
    }
}

@MainActor
final class PushToTalkController {
    static let eventTapMask =
        (CGEventMask(1) &<< CGEventType.keyDown.rawValue)
        | (CGEventMask(1) &<< CGEventType.keyUp.rawValue)
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
    private(set) var shortcut: PushToTalkShortcut
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fallbackGlobalMonitor: Any?
    private var fallbackLocalMonitor: Any?
    private var pressed = false
    private var capsKeyDown = false
    private var lastCapsTap: TimeInterval?

    init(
        shortcut: PushToTalkShortcut = PushToTalkShortcut(rawValue: PerryPreferences.pttShortcut) ?? .optionCommandSpace,
        onPress: @escaping () -> Void,
        onRelease: @escaping () -> Void
    ) {
        self.shortcut = shortcut
        self.onPress = onPress
        self.onRelease = onRelease
    }

    func update(shortcut: PushToTalkShortcut) {
        guard self.shortcut != shortcut else { return }
        resetCaptureState()
        self.shortcut = shortcut
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
                let modifiers = event.flags.intersection([.maskAlternate, .maskCommand]) == [.maskAlternate, .maskCommand]
                let isKeyDown = type == .keyDown
                let isKeyUp = type == .keyUp
                let isDisabled = PushToTalkController.tapIsDisabled(type)
                let timestamp = TimeInterval(event.timestamp) / 1_000_000_000
                Task { @MainActor [weak controller] in
                    controller?.handle(keyCode: keyCode, timestamp: timestamp, isKeyDown: isKeyDown, isKeyUp: isKeyUp, modifiers: modifiers, tapDisabled: isDisabled)
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
        let events: NSEvent.EventTypeMask = [.keyDown, .keyUp]
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
        let modifiers = event.modifierFlags.intersection([.option, .command]) == [.option, .command]
        handle(
            keyCode: keyCode,
            timestamp: event.timestamp,
            isKeyDown: event.type == .keyDown,
            isKeyUp: event.type == .keyUp,
            modifiers: modifiers,
            tapDisabled: false
        )
    }

    func handle(keyCode: Int64, timestamp: TimeInterval, isKeyDown: Bool, isKeyUp: Bool, modifiers: Bool, tapDisabled: Bool) {
        if tapDisabled {
            resetCaptureState()
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }
        switch shortcut {
        case .optionCommandSpace:
            guard keyCode == 49 else { return }
            if isKeyDown, modifiers, !pressed {
                pressed = true
                PerfMark.mark("talk.keydown")
                onPress()
            } else if isKeyUp, pressed {
                releaseIfNeeded()
            }
        case .capsLockDoubleTap:
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
        }
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
        if wasPressed {
            onRelease()
        }
    }
}
