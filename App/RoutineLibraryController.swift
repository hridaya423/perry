import AppKit
import PerryGuide

/// Owns the Watch & Learn flow: armed recording through the review surface
/// into the local routine store, and replay into the foreground Do path.
/// Recording is bounded and nothing persists until the user reviews the
/// inferred steps and names the routine.
@MainActor
final class RoutineLibraryController {
    private let store: RoutineStore
    private let workers: CuaWorkerService
    private let context: GuideSessionContext?
    private let setStatus: (String) -> Void
    private let speak: (String) -> Void
    private let runRoutine: (LearnedRoutine, [String: String]) -> Void
    private let onRecordingChanged: (Bool) -> Void

    private var recorder: DemonstrationRecorder?
    private var pendingRoutine: LearnedRoutine?
    private var pendingRun: LearnedRoutine?
    private var reviewWindow: RoutineReviewWindow?
    private let reviewState = RoutineReviewState()

    init(
        store: RoutineStore,
        workers: CuaWorkerService,
        context: GuideSessionContext?,
        setStatus: @escaping (String) -> Void,
        speak: @escaping (String) -> Void,
        runRoutine: @escaping (LearnedRoutine, [String: String]) -> Void,
        onRecordingChanged: @escaping (Bool) -> Void = { _ in },
        providerCompleter: @escaping @MainActor () -> (@Sendable (String) async throws -> String)? = { nil }
    ) {
        self.providerCompleter = providerCompleter
        self.store = store
        self.workers = workers
        self.context = context
        self.setStatus = setStatus
        self.speak = speak
        self.runRoutine = runRoutine
        self.onRecordingChanged = onRecordingChanged
    }

    private let providerCompleter: @MainActor () -> (@Sendable (String) async throws -> String)?

    var isRecording: Bool { recorder?.isRecording ?? false }

    func routines() -> [LearnedRoutine] { store.all() }

    func run(_ routine: LearnedRoutine) {
        let required = routine.requiredParameters
        guard !required.isEmpty else {
            runRoutine(routine, [:])
            return
        }
        pendingRun = routine
        reviewState.beginFillParameters(routineName: routine.name, parameters: required)
        showReviewWindow()
    }

    private func runPendingRoutine() {
        guard let routine = pendingRun else { return }
        let values = reviewState.parameterValues
        guard values.values.allSatisfy({ $0.count <= LearnedRoutine.parameterValueMaxLength }) else {
            setStatus("A parameter is longer than \(LearnedRoutine.parameterValueMaxLength) characters — shorten it to run this routine.")
            return
        }
        pendingRun = nil
        closeReview()
        runRoutine(routine, values)
    }

    func remove(_ routine: LearnedRoutine) {
        try? store.remove(id: routine.id)
    }

    func importRoutine(from url: URL) {
        do {
            let routine = try store.importRoutine(from: url)
            setStatus("Imported routine \"\(routine.name)\" — run it from the menu.")
        } catch {
            setStatus("The routine could not be imported.")
        }
    }

    func exportRoutine(_ routine: LearnedRoutine, to url: URL) {
        do {
            try store.exportData(routine).write(to: url, options: .atomic)
            setStatus("Exported routine \"\(routine.name)\".")
        } catch {
            setStatus("The routine could not be exported.")
        }
    }

    func toggleRecording() {
        if isRecording {
            Task { await stopRecordingForReview() }
        } else {
            startRecording()
        }
    }

    func stop() {
        discardPendingReview()
    }

    private func startRecording() {
        let recorder = DemonstrationRecorder(
            observe: makeObserver(),
            bundleIDProvider: { [weak self] in
                self?.context?.guideAppBundleID(for: self?.context?.guideTargetHint() ?? CuaTargetHint())
            },
            onEventCount: { [weak self] count in
                self?.reviewState.eventCount = count
            },
            onLimitWarning: { [weak self] in
                self?.setStatus("Recording stops in 30 seconds — finish the step you're on.")
                self?.speak("Recording stops in 30 seconds.")
            },
            onTimeLimit: { [weak self] in
                self?.setStatus("Recording reached its time limit — reviewing what was captured.")
                Task { await self?.stopRecordingForReview() }
            }
        )
        self.recorder = recorder
        reviewState.beginRecording()
        showReviewWindow()
        recorder.start()
        onRecordingChanged(true)
        setStatus("Recording a demonstration — show me the workflow, then Stop & review.")
        speak("Recording. Show me the workflow, then stop and review.")
    }

    private func stopRecordingForReview() async {
        guard let recorder else { return }
        let demonstration = await recorder.stop()
        self.recorder = nil
        onRecordingChanged(false)
        guard let demonstration else {
            closeReview()
            setStatus("Nothing was recorded, so there is no routine to review.")
            return
        }
        do {
            var routine = try RoutineInference.infer(demonstration: demonstration, name: "New routine")
            // Provider synthesis renames/rephrases only — the step structure
            // stays exactly what was recorded; any provider failure keeps the
            // local draft.
            if let complete = providerCompleter() {
                routine = (try? await RoutineSynthesis.polish(routine: routine, complete: complete)) ?? routine
            }
            pendingRoutine = routine
            reviewState.presentReview(steps: routine.steps)
        } catch {
            closeReview()
            setStatus("The demonstration could not be turned into a routine.")
        }
    }

    private func savePendingRoutine() {
        guard var routine = pendingRoutine else { return }
        routine.name = reviewState.name
        for index in reviewState.parameterizedSteps {
            guard routine.steps.indices.contains(index),
                  case .typeText(.literal) = routine.steps[index].action else { continue }
            let field = routine.steps[index].target?.label ?? "this field"
            routine.steps[index].action = .typeText(
                .parameter(name: "text-\(index)", prompt: "Text for \(field)")
            )
            routine.steps[index].summary = "Type text I'll give you into \(field)"
        }
        routine.provenance = .reviewed
        do {
            try store.save(routine)
            setStatus("Saved routine \"\(routine.name)\" — run it from the menu.")
        } catch {
            setStatus("The routine could not be saved: \(error.localizedDescription)")
        }
        pendingRoutine = nil
        closeReview()
    }

    private func discardPendingReview() {
        pendingRoutine = nil
        pendingRun = nil
        Task { _ = await recorder?.stop() }
        if recorder != nil {
            recorder = nil
            onRecordingChanged(false)
        }
        closeReview()
    }

    private func closeReview() {
        reviewWindow?.close()
        reviewWindow = nil
    }

    private func showReviewWindow() {
        if reviewWindow == nil {
            reviewWindow = RoutineReviewWindow(
                state: reviewState,
                onStopRecording: { [weak self] in Task { await self?.stopRecordingForReview() } },
                onDiscard: { [weak self] in self?.discardPendingReview() },
                onSave: { [weak self] in self?.savePendingRoutine() },
                onRun: { [weak self] in self?.runPendingRoutine() }
            )
        }
        reviewWindow?.show()
    }

    /// Read-only window observation for click correlation — the same worker
    /// scope Ask uses for captures.
    private func makeObserver() -> () async throws -> GuideObservation {
        let targetStore = CuaGuideTargetStore()
        return { [workers, context, targetStore] in
            let hint = context?.guideTargetHint() ?? CuaTargetHint()
            await targetStore.set(hint)
            var resources = Set<BackgroundTaskResource>()
            if let bundleID = context?.guideAppBundleID(for: hint) {
                resources.insert(.application(bundleID))
            }
            return try await workers.withWorker(scope: .dictation, resources: resources) { @MainActor worker in
                try await CuaGuideTreeReader(worker: worker, targetStore: targetStore).observe()
            }
        }
    }
}
