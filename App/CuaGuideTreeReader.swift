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

    func observe() async throws -> GuideObservation {
        let capture = try await worker.capture(target: await targetStore.current())
        guard let snapshot = capture.accessibilitySnapshotModel else {
            throw CuaDriverError.noTargetWindow
        }
        let target = capture.target
        return GuideObservation(
            snapshot: snapshot,
            processID: target.processID,
            windowID: target.windowID,
            connectionGeneration: target.connectionGeneration,
            windowBounds: AXElementFrame(x: target.x, y: target.y, width: target.width, height: target.height),
            screenshotData: capture.screenshotData.isEmpty ? nil : capture.screenshotData,
            screenshotMIMEType: capture.screenshotMIMEType
        )
    }
}
