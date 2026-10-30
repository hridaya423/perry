#if DEBUG
import AppKit
import Combine
import Foundation
import PerryBrain
import PerryCore
import PerryGuide
import PerryRuntimes

typealias FullGuideCaptureLoader = @MainActor (CuaWorkerHandle, CuaTargetHint?) async throws -> CuaCapturedWindow
typealias FullGuideContinuationBarrier = @MainActor (UUID) async -> Void
typealias FinalizationPersistenceBarrier = @Sendable () async -> Void

/// Fixture seams the DEBUG harness init and `--perry-debug-*` launch
/// arguments inject into the composition root — each replaces a production
/// collaborator so fixtures stay deterministic. One bag so AppController
/// doesn't carry a dozen properties that exist only for tests.
struct DebugLaunchSeams {
    var storageDirectory: URL?
    var runtimeInventoryLoader: RuntimeCatalog.InventoryLoader?
    var permissionSnapshotLoader: EnvironmentProbe.PermissionSnapshotLoader?
    var cuaHealthLoader: EnvironmentProbe.CuaHealthLoader?
    var screenContextLoader: EnvironmentProbe.ScreenContextLoader?
    var fullGuideCaptureLoader: FullGuideCaptureLoader?
    var fullGuideContinuationBarrier: FullGuideContinuationBarrier?
    var guidePlanner: (any GuidePlanner)?
    var finalizationBarrier: FinalizationBarrier?
    var typedVerifier: (any TypedActionVerifier)?
    var confirmer: (any Confirmer)?
    var askUser: (@Sendable (String, [String]) async throws -> Void)?

    /// `--perry-debug-*` launch arguments → seams. Parsed once in the
    /// production init; the harness init takes seams explicitly.
    static func launch(arguments: [String]) -> DebugLaunchSeams {
        var seams = DebugLaunchSeams()
        if PerryDebugLaunchSurface(arguments: arguments) == .backgroundTasksStorageError,
           let index = arguments.firstIndex(of: "--perry-debug-storage-directory"),
           arguments.indices.contains(index + 1),
           !arguments[index + 1].isEmpty {
            let path = arguments[index + 1]
            var isDirectory = ObjCBool(false)
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                seams.storageDirectory = URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        // `--perry-guide-drill` swaps the model planner for the offline
        // AXGuidePlanner — the lab's Preview click→next-mark drill stays
        // deterministic and needs no provider key.
        if arguments.contains("--perry-guide-drill") {
            seams.guidePlanner = AXGuidePlanner()
        }
        return seams
    }
}
#endif

#if DEBUG
extension AppController {
    func debugSetMaintenanceFixture(
        skipEraseConfirmation: Bool,
        barrier: (@MainActor () async throws -> Void)?
    ) {
        maintenance.debugSetFixture(skipEraseConfirmation: skipEraseConfirmation, barrier: barrier)
    }

    func debugInvokeWipeDataAction() {
        requestCompleteErasure()
    }

    var debugMaintenanceOwnerHeld: Bool {
        maintenance.isUnderMaintenance
    }

    /// Test seam for the dictated-command path — identical to what
    /// VoiceController's dispatch hook delivers after wake word/dictation.
    func debugDispatch(_ text: String, voiceTaskScope: UUID? = nil) {
        commandRouter.route(commandText: text, voiceTaskScope: voiceTaskScope)
    }

    /// Seeds the History fixture and opens History for the capture lane.
    func debugShowHistoryFixture() {
        Task { @MainActor in
            for entry in PerryDebugLaunchSurface.historyEntries() {
                await transcriptStore.append(entry)
            }
            showHistory()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Applies a deterministic `DebugStateFixture` — see DebugStateFixtures.swift.
    func applyDebugStateFixture(_ fixture: DebugStateFixture) {
        switch fixture {
        case .permissionDenied:
            onboarding.runDenied()
        case .approvalOrange, .approvalRed:
            guard let card = fixture.intentCard else { return }
            intentCards.showFixture(card)
        default:
            if let state = fixture.sessionState {
                sessionController.debugSet(state)
            }
            if let status = fixture.statusText {
                sessionStatus = status
            }
            showPanel()
        }
    }

    /// True when an early-return debug surface consumed the launch path.
    func debugHandleEarlyLaunchSurface() -> Bool {
        let debugSurface = PerryDebugLaunchSurface(arguments: ProcessInfo.processInfo.arguments)
        if debugSurface == .backgroundTasksStorageError {
            guard debugSeams.storageDirectory != nil else { return true }
            DispatchQueue.main.async { [weak self] in
                self?.showDebugBackgroundTasksStorageError()
            }
            return true
        }
        return false
    }

    /// Presents the --perry-debug-* surface the launch arguments asked for
    /// (or runs onboarding when none did), then applies any state fixture.
    func applyDebugLaunchSurface() {
        let debugSurface = PerryDebugLaunchSurface(arguments: ProcessInfo.processInfo.arguments)
        if debugSurface == nil {
            onboarding.runIfNeeded()
        }
        if debugSurface == .settings {
            DispatchQueue.main.async { [weak self] in
                self?.showSettings()
                NSApp.activate(ignoringOtherApps: true)
            }
        } else if debugSurface == .onboarding {
            DispatchQueue.main.async { [weak self] in
                self?.onboarding.runDenied()
            }
        } else if debugSurface == .session {
            DispatchQueue.main.async { [weak self] in
                self?.showPanel()
            }
        } else if debugSurface == .activity {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.foreground.debugShowActivityFixture()
            }
        } else if debugSurface == .guideControls {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.guideCoordinator.debugShowGuideControlsFixture()
            }
        } else if debugSurface == .history {
            DispatchQueue.main.async { [weak self] in
                self?.debugShowHistoryFixture()
            }
        } else if debugSurface == .intentCard {
            DispatchQueue.main.async {
                Task { @MainActor in _ = await IntentCardPresenter.shared.present(card: PerryDebugLaunchSurface.intentCardFixture, allowsStepThrough: true) }
            }
        } else if debugSurface == .notch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.notchStatus.update(isRecording: true, backgroundCount: 2, awaitingApproval: 1)
            }
        } else if debugSurface == .backgroundTasksStorageError {
            DispatchQueue.main.async { [weak self] in
                self?.showBackgroundTasks()
            }
        }
        if let fixture = DebugStateFixture(arguments: ProcessInfo.processInfo.arguments) {
            DispatchQueue.main.async { [weak self] in
                self?.applyDebugStateFixture(fixture)
            }
        }
    }

    func runFailureDrill(_ drill: FailureDrill) {
        switch drill {
        case .routeFlip:
            voice.speak("The audio route drill is speaking now.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.voice.debugSimulateAudioRouteChange("simulated AirPods")
            }
        case .microphoneWedge:
            voice.debugSimulateDictationFailure()
        case .mutedOutput:
            let message = "This reply is from the muted-output recovery drill."
            voice.speak(message)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.voice.copyReplyToClipboard(
                    message,
                    status: "Muted-output drill passed; the reply is on your clipboard."
                )
            }
        case .runtimeMissing:
            runOnboarding(force: true)
            voice.speak("The runtime precheck drill stopped here honestly. Install Codex or Claude Code, then try again.")
        }
    }

    func installTalkDrillTrigger() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("app.perry.talk-drill"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            switch note.userInfo?["phase"] as? String {
            case "down":
                self.modifierHoldMonitor.handle(timestamp: now, modifiers: [.control], isFlagsChanged: true, tapDisabled: false)
                self.modifierHoldMonitor.handle(timestamp: now, modifiers: [.control, .option], isFlagsChanged: true, tapDisabled: false)
            case "up":
                self.modifierHoldMonitor.handle(timestamp: now, modifiers: [.control], isFlagsChanged: true, tapDisabled: false)
                self.modifierHoldMonitor.handle(timestamp: now, modifiers: [], isFlagsChanged: true, tapDisabled: false)
            default:
                break
            }
        }
    }
    /// Phase-3 lab seam: `app.perry.guide-drill` notifications carrying a
    /// `goal` string start a real guide session on the frontmost app —
    /// scripts/lab/guide-drill.sh drives Preview through it end to end.
    func installGuideDrillTrigger() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("app.perry.guide-drill"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let goal = note.userInfo?["goal"] as? String,
                  !goal.isEmpty else { return }
            _ = self.guideCoordinator.startGuiding(goal: goal)
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("app.perry.guide-drill-click"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let x = (note.userInfo?["x"] as? NSNumber)?.doubleValue,
                  let y = (note.userInfo?["y"] as? NSNumber)?.doubleValue else { return }
            guard note.userInfo?["real"] as? Bool == true else {
                self.guideCoordinator.debugGuideDrillClick(axX: x, axY: y)
                return
            }
            let point = CGPoint(x: x, y: y)
            for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
                CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
                usleep(40_000)
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("app.perry.guide-drill-stop"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.guideCoordinator.dismissIfActive()
        }
        // A postcondition-less step parks at .stillWaiting after a real hit —
        // the shipped UX resolves that with the controls' Done button, which
        // routes to advanceGuide()/engine.userActed(). The drill drives the
        // identical path.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("app.perry.guide-drill-done"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.guideCoordinator.advanceGuide()
        }
    }

    func installOverlayDump() {
        guard let path = ProcessInfo.processInfo.environment["PERRY_OVERLAY_DUMP"] else { return }
        FileManager.default.createFile(atPath: path, contents: nil)
        overlayDump = overlayState.$visualGuidanceOverlays.sink { overlays in
            let row: [String: Any] = [
                "at": Date().timeIntervalSince1970,
                "overlays": overlays.compactMap { (try? JSONSerialization.jsonObject(with: JSONEncoder().encode($0))) },
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: row),
                  let handle = FileHandle(forWritingAtPath: path) else { return }
            handle.seekToEndOfFile()
            handle.write(data + Data([0x0a]))
            try? handle.close()
        }
    }

    func installTaskDrillTrigger() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("app.perry.task-drill"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, let goal = note.userInfo?["goal"] as? String, !goal.isEmpty else { return }
            self.debugDispatch(goal)
        }
    }

    func showDebugBackgroundTasksStorageError() {
        homeController.openHome(selection: .tasks)
    }
}
#endif

#if DEBUG
enum AgentTrace {
    private static let file = ProcessInfo.processInfo.environment["PERRY_AGENT_TRACE"].map { URL(fileURLWithPath: $0) }

    static func record(_ event: AgentLoopEvent) {
        guard let file else { return }
        var row: [String: JSONValue] = ["at": .number(Date().timeIntervalSince1970)]
        switch event {
        case .textDelta(let text): row["text"] = .string(text)
        case .toolCallStarted(let call): row["tool"] = .string(call.name); row["arguments"] = call.arguments
        case .toolCallFinished(let result):
            row["result"] = .string(result.content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: " ").prefix(20000).description)
            row["error"] = .bool(result.isError)
            for case .image(let data, let mimeType) in result.content {
                let image = file.appendingPathExtension("\(Int(Date().timeIntervalSince1970 * 1000)).\(mimeType.hasSuffix("png") ? "png" : "jpg")")
                try? data.write(to: image)
                row["image"] = .string(image.lastPathComponent)
            }
        case .finished(let finish): row["finished"] = .string(String(describing: finish))
        case .note(let note): row["note"] = .string(note)
        case .draw: return
        }
        guard var line = try? JSONValue.object(row).data() else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: file)
        }
    }
}
#endif
