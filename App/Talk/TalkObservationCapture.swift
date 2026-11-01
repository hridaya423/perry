import ApplicationServices
import PerryCore
import PerryGuide

@MainActor
final class TalkObservationCapture {
    private let workers: ScreenWorkerService
    private let targetHint: () -> ScreenTargetHint
    private let appBundleID: (ScreenTargetHint) -> String?
    private let targetStore = ScreenGuideTargetStore()

    init(
        workers: ScreenWorkerService,
        targetHint: @escaping () -> ScreenTargetHint,
        appBundleID: @escaping (ScreenTargetHint) -> String?
    ) {
        self.workers = workers
        self.targetHint = targetHint
        self.appBundleID = appBundleID
    }

    func capture() async throws -> GuideObservation {
        PerfMark.mark("talk.capture_begin")
        let hint = targetHint()
        await targetStore.set(hint)
        do {
            try Task.checkCancellation()
            if AXIsProcessTrusted() {
                do {
                    let observation = try await LocalTalkObserver(
                        hint: hint,
                        pointerAXPoint: PointerTraceRecorder.mouseLocationInAXSpace(),
                        targetStore: targetStore
                    ).observe()
                    PerfMark.mark("talk.capture_local")
                    if observation.screenshotData == nil {
                        PerfMark.mark("talk.capture_no_screenshot")
                    }
                    PerfMark.mark("capture.done")
                    return observation
                } catch {
                    PerfMark.markDynamic("talk.capture_local_failed.\(String(describing: error))")
                    TalkSession.logger.error("local capture failed: \(String(describing: error), privacy: .public)")
                }
            }
            try Task.checkCancellation()
            var resources = Set<BackgroundTaskResource>()
            if let bundleID = appBundleID(hint) {
                resources.insert(.application(bundleID))
            }
            let observation = try await workers.withWorker(scope: .dictation, resources: resources) { @MainActor worker in
                try await ScreenGuideTreeReader(worker: worker, targetStore: self.targetStore).observe()
            }
            PerfMark.mark("capture.done")
            return observation
        } catch {
            PerfMark.markDynamic("talk.capture_failed.\(String(describing: error))")
            TalkSession.logger.error("capture failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }
}
