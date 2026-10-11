import ApplicationServices
import PerryCapture
import PerryCore
import PerryGuide

/// Talk's screen capture. The local observer (window list + AX hit-test +
/// bounded index + ScreenCaptureKit) runs first — it's ~10x faster than the
/// driver tree walk and claims no worker. The driver path remains for when
/// Perry lacks grants or the local walk fails.
@MainActor
final class TalkObservationCapture {
    private let workers: CuaWorkerService
    private let targetHint: () -> CuaTargetHint
    private let appBundleID: (CuaTargetHint) -> String?
    private let targetStore = CuaGuideTargetStore()

    init(
        workers: CuaWorkerService,
        targetHint: @escaping () -> CuaTargetHint,
        appBundleID: @escaping (CuaTargetHint) -> String?
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
                }
            }
            var resources = Set<BackgroundTaskResource>()
            if let bundleID = appBundleID(hint) {
                resources.insert(.application(bundleID))
            }
            let observation = try await workers.withWorker(scope: .dictation, resources: resources) { @MainActor worker in
                try await CuaGuideTreeReader(worker: worker, targetStore: self.targetStore).observe()
            }
            PerfMark.mark("capture.done")
            return observation
        } catch {
            PerfMark.markDynamic("talk.capture_failed.\(String(describing: error))")
            throw error
        }
    }
}
