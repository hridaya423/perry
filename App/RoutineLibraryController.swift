import AppKit
import PerryGuide

@MainActor
final class RoutineLibraryController {
    private let store: RoutineStore
    private let workers: CuaWorkerService
    private let context: GuideSessionContext?
    private let setStatus: (String) -> Void
    private let speak: (String) -> Void
    private let runRoutine: (LearnedRoutine, [String: String]) -> Void
    private let onRecordingChanged: (Bool) -> Void
    private let showRing: (AXElementFrame) -> Void
    private let inputMonitoringGranted: () -> Bool
    private let guideInputMonitoring: () async -> GrantMonitor.Status

    private var recorder: DemonstrationRecorder?
    private var pendingRoutine: LearnedRoutine?
    private var pendingRun: LearnedRoutine?
    private let reviewID = UUID()
    private let reviewState = RoutineReviewState()

    init(
        store: RoutineStore,
        workers: CuaWorkerService,
        context: GuideSessionContext?,
        setStatus: @escaping (String) -> Void,
        speak: @escaping (String) -> Void,
        runRoutine: @escaping (LearnedRoutine, [String: String]) -> Void,
        onRecordingChanged: @escaping (Bool) -> Void = { _ in },
        showRing: @escaping (AXElementFrame) -> Void = { _ in },
        inputMonitoringGranted: @escaping () -> Bool = { PermissionCheck.granted(.inputMonitoring) },
        guideInputMonitoring: @escaping () async -> GrantMonitor.Status = { await PermissionGuideCoordinator.guide(.inputMonitoring) },
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
        self.showRing = showRing
        self.inputMonitoringGranted = inputMonitoringGranted
        self.guideInputMonitoring = guideInputMonitoring
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
            setStatus("A parameter is longer than \(LearnedRoutine.parameterValueMaxLength) characters. Shorten it to run this routine.")
            return
        }
        pendingRun = nil
        closeReview()
        runRoutine(routine, values)
    }

    func recordVerifiedRun(_ id: UUID) {
        try? store.recordVerifiedRun(id: id)
    }

    func remove(_ routine: LearnedRoutine) {
        try? store.remove(id: routine.id)
    }

    func importRoutine(from url: URL) {
        do {
            let routine = try store.importRoutine(from: url)
            setStatus("Imported routine \"\(routine.name)\". Run it from the menu.")
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
            Task { await beginRecording() }
        }
    }

    func beginRecording() async {
        guard !isRecording else { return }
        if !inputMonitoringGranted() {
            switch await guideInputMonitoring() {
            case .granted:
                break
            case .needsRelaunch:
                setStatus("Input Monitoring is on. Restart Perry, then start the recording again.")
                speak("Input Monitoring is on. Restart Perry, then start the recording again.")
                return
            case .notGranted:
                setStatus("I need Input Monitoring to see your typing, so I have not started recording.")
                return
            }
        }
        startRecording()
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
            onRecognizedControl: { [weak self] frame in
                self?.showRing(frame)
            },
            onCancelRequested: { [weak self] in
                self?.discardPendingReview()
                self?.setStatus("Recording cancelled. Nothing was saved.")
            },
            onLimitWarning: { [weak self] in
                self?.setStatus("Recording stops in 30 seconds. Finish the step you’re on.")
                self?.speak("Recording stops in 30 seconds.")
            },
            onTimeLimit: { [weak self] in
                self?.setStatus("Recording reached its time limit. Reviewing what was captured.")
                Task { await self?.stopRecordingForReview() }
            }
        )
        self.recorder = recorder
        reviewState.beginRecording()
        showReviewWindow()
        recorder.start()
        onRecordingChanged(true)
        setStatus("Recording a demonstration. Show me the workflow, then choose Done.")
        speak("Recording. Show me the workflow, then choose Done.")
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

    private func savePendingRoutine(thenRun: Bool = false) {
        guard var routine = pendingRoutine else { return }
        routine.name = reviewState.name
        for index in reviewState.parameterizedSteps {
            guard routine.steps.indices.contains(index),
                  case .typeText(.literal) = routine.steps[index].action else { continue }
            let field = routine.steps[index].target?.label ?? "this field"
            routine.steps[index].action = .typeText(
                .parameter(name: "text-\(index)", prompt: "Text for \(field)")
            )
            routine.steps[index].summary = "Type text I’ll give you into \(field)"
        }
        routine.provenance = .reviewed
        var saved = false
        do {
            try store.save(routine)
            saved = true
            setStatus("Saved routine “\(routine.name)”. Run it from the menu.")
        } catch {
            setStatus("The routine could not be saved: \(error.localizedDescription)")
        }
        pendingRoutine = nil
        closeReview()
        if saved, thenRun { run(routine) }
    }

    private func discardPendingReview() {
        pendingRoutine = nil
        pendingRun = nil
        if let recorder {
            Task { _ = await recorder.stop() }
            self.recorder = nil
            onRecordingChanged(false)
        }
        closeReview()
    }

    private func closeReview() {
        NotchPresentation.shared.remove(reviewID)
    }

    private func showReviewWindow() {
        NotchPresentation.shared.present(id: reviewID, priority: .routine, content: RoutineReviewView(
            state: reviewState,
            onStopRecording: { [weak self] in Task { await self?.stopRecordingForReview() } },
            onDiscard: { [weak self] in self?.discardPendingReview() },
            onSave: { [weak self] in self?.savePendingRoutine() },
            onSaveAndTry: { [weak self] in self?.savePendingRoutine(thenRun: true) },
            onRun: { [weak self] in self?.runPendingRoutine() }
        ))
    }

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
