import AppKit

@MainActor
final class PushToTalkController {
    private let onPress: () -> Void
    private let onRelease: () -> Void
    private(set) var gesture: Gesture
    private lazy var source = KeyEventSource { [weak self] event in
        guard let self else { return }
        if event.kind == .flagsChanged, event.keyCode == 57, self.gesture == .doubleTap([.capsLock]) {
            self.capsLockToggled(at: event.timestamp, flags: event.flags)
            return
        }
        self.handle(
            keyCode: event.keyCode,
            timestamp: event.timestamp,
            flags: event.flags,
            isKeyDown: event.kind == .keyDown,
            isKeyUp: event.kind == .keyUp,
            tapDisabled: event.kind == .tapDisabled
        )
    }
    private var pressed = false
    private var capsKeyDown = false
    private var lastCapsTap: TimeInterval?
    private var lastFlags: CGEventFlags = []
    private var modifierHoldPending = false
    private var modifierHoldChord = false
    private var modifierHoldWorkItem: DispatchWorkItem?

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

    var captureMode: KeyEventSource.Capture? { source.capture }

    func start() {
        source.start()
        PerfMark.mark(source.capture == .eventTap ? "ptt.capture.eventtap" : "ptt.capture.fallback")
    }

    func stop() {
        source.stop()
        resetCaptureState()
    }

    func capsLockToggled(at timestamp: TimeInterval, flags: CGEventFlags) {
        handle(keyCode: 57, timestamp: timestamp, flags: flags, isKeyDown: true, isKeyUp: false, tapDisabled: false)
        handle(keyCode: 57, timestamp: timestamp, flags: flags, isKeyDown: false, isKeyUp: true, tapDisabled: false)
    }

    func handle(keyCode: Int64, timestamp: TimeInterval, flags: CGEventFlags, isKeyDown: Bool, isKeyUp: Bool, tapDisabled: Bool) {
        if tapDisabled {
            resetCaptureState()
            source.reenable()
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
