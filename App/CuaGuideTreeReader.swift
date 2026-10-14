import Foundation
import PerryGuide

actor CuaGuideTargetStore {
    private var targetHint: CuaTargetHint?

    func set(_ targetHint: CuaTargetHint?) {
        self.targetHint = targetHint
    }

    func current() -> CuaTargetHint? {
        targetHint
    }
}

struct CuaGuideTreeReader: GuideObserving {
    let worker: CuaWorkerHandle
    let targetStore: CuaGuideTargetStore
    let changes = AXAppChangeMonitor()

    func observe() async throws -> GuideObservation {
        try await observation(includeScreenshot: true)
    }

    /// Verification reads skip the screenshot — the postcondition checks the
    /// element index, never pixels.
    func observeElements() async throws -> GuideObservation {
        try await observation(includeScreenshot: false)
    }

    /// Postconditionless verifies only need to prove the bound window is
    /// still ours: resolve the stored hint (windowID match-or-die, then the
    /// pid+title continuity retry) and return identity without the AX walk.
    func probeTarget() async throws -> GuideObservation {
        let hint = await targetStore.current()
        let target = try await probe(hint: hint)
        await targetStore.set(target.hint)
        return GuideObservation(
            snapshot: AXSnapshot(appBundleID: target.bundleID, windowTitle: target.title, elements: []),
            processID: target.processID,
            windowID: target.windowID,
            connectionGeneration: target.connectionGeneration,
            windowBounds: AXElementFrame(x: target.x, y: target.y, width: target.width, height: target.height)
        )
    }

    /// Same stale-window rescue as the full read, mirrored for probes.
    private func probe(hint: CuaTargetHint?) async throws -> CuaWindowTarget {
        do {
            return try await worker.probeTarget(hint)
        } catch let error as CuaDriverError where error == .noTargetWindow {
            guard let hint,
                  hint.windowID != nil,
                  hint.processID != nil,
                  let title = hint.windowTitle,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw error }
            return try await worker.probeTarget(CuaTargetHint(
                bundleID: hint.bundleID,
                processID: hint.processID,
                windowTitle: hint.windowTitle
            ))
        }
    }

    /// Waits on the target app's AX change notifications. Without a resolved
    /// pid there is nothing to watch — return unsignaled so the caller still
    /// reads once, matching the poll-based path this replaces.
    func awaitUIChange(within: Duration) async -> Bool {
        guard let pid = await targetStore.current()?.processID else { return false }
        PerfMark.mark("guide.await.begin")
        defer { PerfMark.mark("guide.await.end") }
        return await changes.waitForChange(pid: pid_t(pid), within: within)
    }

    private func observation(includeScreenshot: Bool) async throws -> GuideObservation {
        let hint = await targetStore.current()
        let capture: CuaCapturedWindow
        PerfMark.mark("guide.observe.begin")
        defer { PerfMark.mark("guide.observe.end") }
        do {
            capture = try await worker.capture(target: hint, includeScreenshot: includeScreenshot)
        } catch let error as CuaDriverError where error == .noTargetWindow {
            // Re-observe is continuity, not a fresh binding: the window may
            // have been recreated mid-guide (resize, zoom, sheet attach),
            // leaving the stored windowID stale. Retry scoped to pid+title —
            // the same logical window — while a bare-id miss stays fatal.
            guard let hint,
                  hint.windowID != nil,
                  hint.processID != nil,
                  let title = hint.windowTitle,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw error }
            let rebound = CuaTargetHint(
                bundleID: hint.bundleID,
                processID: hint.processID,
                windowTitle: hint.windowTitle
            )
            capture = try await worker.capture(target: rebound, includeScreenshot: includeScreenshot)
        }
        guard let snapshot = capture.accessibilitySnapshotModel else {
            throw CuaDriverError.noTargetWindow
        }
        let target = capture.target
        await targetStore.set(target.hint)
        return GuideObservation(
            snapshot: snapshot,
            processID: target.processID,
            windowID: target.windowID,
            connectionGeneration: target.connectionGeneration,
            windowBounds: AXElementFrame(x: target.x, y: target.y, width: target.width, height: target.height),
            screenshotData: capture.screenshotData.isEmpty ? nil : capture.screenshotData,
            screenshotMIMEType: capture.screenshotMIMEType,
            observationID: capture.snapshotID
        )
    }
}
