import AppKit

enum TalkGesture {
    static var keys: String { PerryPreferences.talkGesture.keys }
    static var talk: String { "\(PerryPreferences.talkGesture.spoken) to talk" }
    static var steer: String { "\(PerryPreferences.talkGesture.spoken) to steer" }
    static var type: String { "\(PerryPreferences.typeGesture.spoken) to type" }
}

@MainActor
final class ModifierHoldMonitor {
    private let commitDelay: TimeInterval
    private let talkHold: () -> ModifierSet
    private let typeTap: () -> ModifierSet
    private let onHoldStart: () -> Void
    private let onHoldCommit: () -> Void
    private let onHoldEnd: () -> Void
    private let onHoldCancel: () -> Void
    private let onHoldTap: () -> Void
    private let onComposer: () -> Void
    private lazy var source = KeyEventSource { [weak self] event in
        guard let self else { return }
        switch event.kind {
        case .keyDown:
            handleKeyDown(keyCode: event.keyCode)
        case .flagsChanged:
            handle(timestamp: event.timestamp, modifiers: ModifierSet(event.flags), isFlagsChanged: true, tapDisabled: false)
        case .tapDisabled:
            handle(timestamp: event.timestamp, modifiers: [], isFlagsChanged: false, tapDisabled: true)
        case .keyUp:
            break
        }
    }

    private var holding = false
    private var swallowing = false
    var captureMode: KeyEventSource.Capture? { source.capture }
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
        source.start()
    }

    func stop() {
        source.stop()
        resetCaptureState()
    }

    func handle(timestamp: TimeInterval, modifiers: ModifierSet, isFlagsChanged: Bool, tapDisabled: Bool) {
        let typeSet = typeTap()
        let typeHeld = modifiers.isSuperset(of: typeSet)
        if tapDisabled {
            resetCaptureState()
            source.reenable()
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
