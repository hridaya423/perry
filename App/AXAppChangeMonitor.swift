import ApplicationServices
import Foundation

/// Watches one target app's AX notifications so Guide verification can wait
/// on real UI changes instead of a fixed poll. AX posts propagate to
/// observers registered on ancestor elements, so subscribing on the
/// application element covers the whole window tree without per-element
/// registration — and without a screen capture.
///
/// Notifications that arrive between waits are counted, not dropped: a change
/// that lands after the user's click but before the engine suspends still
/// ends the wait immediately. The notification set is deliberately narrow —
/// the four `GuideStep.Postcondition` shapes plus the transitions a step can
/// predict — because a chatty app could otherwise turn verification into a
/// read storm.
final class AXAppChangeMonitor: @unchecked Sendable {
    private struct State {
        var observer: AXObserver?
        var observedPID: pid_t?
        var pending = 0
        var delivered = 0
        var waiter: CheckedContinuation<Bool, Never>?
        var timeout: Task<Void, Never>?
    }

    private let lock = NSLock()
    private var state = State()

    private static let notifications: [String] = [
        kAXCreatedNotification,
        kAXUIElementDestroyedNotification,
        kAXFocusedUIElementChangedNotification,
        kAXValueChangedNotification,
        kAXTitleChangedNotification,
        kAXWindowCreatedNotification,
    ]

    deinit { tearDownObserver() }

    /// Suspends until the app signals a change or `within` elapses. True means
    /// a signal ended the wait. Returns false immediately when Perry cannot
    /// observe the process — the caller still reads once, preserving the
    /// poll-based semantics this replaces.
    func waitForChange(pid: pid_t, within: Duration) async -> Bool {
        guard within > .zero, ensureObserver(pid: pid) else { return false }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                lock.lock()
                if state.pending > state.delivered {
                    state.delivered = state.pending
                    lock.unlock()
                    cont.resume(returning: true)
                    return
                }
                // A second concurrent waiter would strand the first — wake it
                // as timed-out rather than leak the continuation.
                state.waiter?.resume(returning: false)
                state.timeout?.cancel()
                state.waiter = cont
                lock.unlock()
                let timeout = Task { [weak self] in
                    try? await Task.sleep(for: within)
                    self?.resumeWaiter(signaled: false)
                }
                lock.lock()
                if state.waiter == nil {
                    lock.unlock()
                    timeout.cancel()
                } else {
                    state.timeout = timeout
                    lock.unlock()
                }
            }
        } onCancel: { [weak self] in
            self?.resumeWaiter(signaled: false)
        }
    }

    private func noteSignal() {
        lock.lock()
        state.pending += 1
        let waiter = state.waiter
        if waiter != nil {
            state.waiter = nil
            state.delivered = state.pending
            state.timeout?.cancel()
            state.timeout = nil
        }
        lock.unlock()
        waiter?.resume(returning: true)
    }

    private func resumeWaiter(signaled: Bool) {
        lock.lock()
        let waiter = state.waiter
        state.waiter = nil
        state.timeout = nil
        if waiter != nil, signaled {
            state.delivered = state.pending
        }
        lock.unlock()
        waiter?.resume(returning: signaled)
    }

    private func ensureObserver(pid: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if state.observedPID == pid, state.observer != nil { return true }
        tearDownObserverLocked()
        guard AXIsProcessTrusted() else { return false }
        var observer: AXObserver?
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverCreate(pid, { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<AXAppChangeMonitor>.fromOpaque(refcon)
                .takeUnretainedValue()
                .noteSignal()
        }, &observer) == .success, let observer else { return false }
        let app = AXUIElementCreateApplication(pid)
        for name in Self.notifications {
            AXObserverAddNotification(observer, app, name as CFString, refcon)
        }
        let runLoop = CFRunLoopGetMain()
        CFRunLoopAddSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
        CFRunLoopWakeUp(runLoop)
        state.observer = observer
        state.observedPID = pid
        state.pending = 0
        state.delivered = 0
        return true
    }

    private func tearDownObserverLocked() {
        guard let observer = state.observer else { return }
        let app = state.observedPID.map { AXUIElementCreateApplication($0) }
        if let app {
            for name in Self.notifications {
                AXObserverRemoveNotification(observer, app, name as CFString)
            }
        }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        state.observer = nil
        state.observedPID = nil
    }

    private func tearDownObserver() {
        lock.lock()
        tearDownObserverLocked()
        lock.unlock()
    }
}
