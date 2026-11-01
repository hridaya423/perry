import Foundation
import PerryGuide

actor ScreenGuideTargetStore {
    private var targetHint: ScreenTargetHint?

    func set(_ targetHint: ScreenTargetHint?) {
        self.targetHint = targetHint
    }

    func current() -> ScreenTargetHint? {
        targetHint
    }
}

struct ScreenGuideTreeReader: GuideObserving {
    let worker: ScreenWorkerHandle
    let targetStore: ScreenGuideTargetStore
    let changes = AXAppChangeMonitor()

    func observe() async throws -> GuideObservation {
        try await observation(includeScreenshot: true)
    }

    func observeElements() async throws -> GuideObservation {
        try await observation(includeScreenshot: false)
    }

    func probeTarget() async throws -> GuideObservation {
        let hint = await targetStore.current()
        let target = try await rebindingStaleWindow(hint) { try await worker.probeTarget($0) }
        await targetStore.set(target.hint)
        return GuideObservation(
            snapshot: AXSnapshot(appBundleID: target.bundleID, windowTitle: target.title, elements: []),
            processID: target.processID,
            windowID: target.windowID,
            connectionGeneration: target.connectionGeneration,
            windowBounds: AXElementFrame(x: target.x, y: target.y, width: target.width, height: target.height)
        )
    }

    func awaitUIChange(within: Duration) async -> Bool {
        guard let pid = await targetStore.current()?.processID else { return false }
        PerfMark.mark("guide.await.begin")
        defer { PerfMark.mark("guide.await.end") }
        return await changes.waitForChange(pid: pid_t(pid), within: within)
    }

    private func rebindingStaleWindow<Value>(
        _ hint: ScreenTargetHint?,
        _ read: (ScreenTargetHint?) async throws -> Value
    ) async throws -> Value {
        do {
            return try await read(hint)
        } catch let error as ScreenDriverError where error == .noTargetWindow {
            guard let hint,
                  hint.windowID != nil,
                  hint.processID != nil,
                  let title = hint.windowTitle,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw error }
            return try await read(ScreenTargetHint(
                bundleID: hint.bundleID,
                processID: hint.processID,
                windowTitle: hint.windowTitle
            ))
        }
    }

    private func observation(includeScreenshot: Bool) async throws -> GuideObservation {
        let hint = await targetStore.current()
        PerfMark.mark("guide.observe.begin")
        defer { PerfMark.mark("guide.observe.end") }
        let capture = try await rebindingStaleWindow(hint) {
            try await worker.capture(target: $0, includeScreenshot: includeScreenshot)
        }
        guard let snapshot = capture.accessibilitySnapshotModel else {
            throw ScreenDriverError.noTargetWindow
        }
        let target = capture.target
        await targetStore.set(target.hint)
        let menuBar = MenuBarReader.elements(pid: pid_t(target.processID))
        let menuOpen = menuBar.contains { $0.role == .menuItem }
        let windowElements = menuOpen ? snapshot.elements.filter { $0.role != .menu && $0.role != .menuItem } : snapshot.elements
        return GuideObservation(
            snapshot: AXSnapshot(
                appBundleID: snapshot.appBundleID, windowTitle: snapshot.windowTitle,
                elements: windowElements + menuBar
            ),
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
