import AppKit
import AVFoundation
import SwiftUI
import PerryCore
import PerryOverlay
import PerryCapture
import PerryGuide
import PerryRuntimes

/// Owns the live session: hotkey → overlay + panel, Guide/Do flows, intent
/// cards, notifications, memory. Everything the PRD's Session Orchestrator
/// implies, bound to real UI.
@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    static let shared = AppController()

    private var hotkey: HotkeyController?
    private let overlayState = PerryCursorState()
    private lazy var overlayManager = OverlayWindowManager()
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var intentCardWindow: IntentCardWindow?

    private lazy var guideEngine = GuideEngine(planner: AXGuidePlanner(), reader: LiveAXTreeReader())
    private lazy var activityLog = ActivityLog(storageDirectory: Self.supportDirectory)
    private lazy var memoryStore = MemoryStore(storageDirectory: Self.supportDirectory)
    private let notifier = SystemNotifier()
    private lazy var backgroundRunner = BackgroundTaskRunner(notifier: notifier)
    private var onboardingFlow: OnboardingFlow?

    enum Mode: String {
        case idle, listening, guiding, doing
    }
    private(set) var mode: Mode = .idle

    static var supportDirectory: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Perry", isDirectory: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        ensureSupportDirectory()
        installStatusItem()
        installHotkey()
        runOnboardingIfNeeded()
    }

    private func ensureSupportDirectory() {
        guard let directory = Self.supportDirectory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: Wake / dismiss

    private func installHotkey() {
        hotkey = HotkeyController { [weak self] in
            Task { @MainActor in self?.toggleSession() }
        }
    }

    func toggleSession() {
        if mode == .idle {
            wake()
        } else {
            dismiss()
        }
    }

    private func wake() {
        mode = .listening
        overlayManager.showOverlay(onScreens: NSScreen.screens, state: overlayState)
        showPanel()
        speak("Perry here.")
    }

    func dismiss() {
        mode = .idle
        Task { await guideEngine.stop() }
        overlayManager.fadeOutAndHideOverlay()
        hidePanel()
    }

    // MARK: Status item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🦫"
        item.menu = buildMenu()
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Wake Perry (⌥⌘P)", action: #selector(wakeAction), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Guide me…", action: #selector(guidePromptAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show me everything", action: #selector(everythingAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Do a task…", action: #selector(doPromptAction), keyEquivalent: "").target = self
        menu.addItem(.separator())

        let memoryItem = NSMenuItem(title: "Memory: on", action: #selector(toggleMemoryAction), keyEquivalent: "")
        memoryItem.target = self
        menu.addItem(memoryItem)

        let wipeItem = NSMenuItem(title: "Wipe memory & logs", action: #selector(wipeDataAction), keyEquivalent: "")
        wipeItem.target = self
        menu.addItem(wipeItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Perry", action: #selector(quitAction), keyEquivalent: "q").target = self
        return menu
    }

    @objc private func wakeAction() { wake() }
    @objc private func quitAction() { NSApp.terminate(nil) }

    @objc private func guidePromptAction() {
        wake()
        speak("What should I teach you? Type it or press the mic.")
    }

    @objc private func everythingAction() {
        Task { await showEverything(goal: "walk through the frontmost window") }
    }

    @objc private func doPromptAction() {
        wake()
        speak("Tell me what to take off your hands.")
    }

    @objc private func toggleMemoryAction() {
        Task {
            let current = await memoryStore.currentConfiguration()
            await memoryStore.setConfiguration(MemoryConfiguration(enabled: !current.enabled))
        }
    }

    @objc private func wipeDataAction() {
        Task {
            await memoryStore.wipe()
            await activityLog.wipe()
            speak("Memory and logs wiped.")
        }
    }

    // MARK: Panel (the type/talk surface)

    private func showPanel() {
        if panel == nil {
            let host = NSHostingView(rootView: SessionPanelView(controller: self))
            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 120),
                styleMask: [.titled, .nonactivatingPanel, .utilityWindow],
                backing: .buffered,
                defer: false
            )
            p.contentView = host
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false
            p.level = .floating
            panel = p
        }
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel?.setFrameOrigin(
                NSPoint(x: frame.maxX - 400, y: frame.minY + 140)
            )
        }
        panel?.orderFrontRegardless()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
    }

    // MARK: Guide flows

    func startGuiding(goal: String) {
        Task { @MainActor in
            do {
                mode = .guiding
                if !overlayManager.isShowingOverlay() {
                    overlayManager.showOverlay(onScreens: NSScreen.screens, state: overlayState)
                }
                if let firstStep = try await guideEngine.start(goal: goal) {
                    present(step: firstStep)
                    speak(firstStep.instruction)
                } else {
                    speak("I couldn't see anything to point at there.")
                }
            } catch {
                speak("I need Accessibility permission to see your screen first.")
                runOnboarding(force: true)
            }
        }
    }

    func advanceGuide() {
        Task { @MainActor in
            let result = await guideEngine.userActed()
            switch result {
            case .advanced(let step, _):
                present(step: step)
                speak(step.instruction)
            case .finished:
                speak("That's the whole flow. Nice.")
                dismiss()
            case .stillWaiting:
                break
            case .notPresenting:
                break
            }
        }
    }

    func showEverything(goal: String) async {
        guard let snapshot = try? await LiveAXTreeReader().readFrontmost() else {
            speak("Give me Accessibility permission and I can paint the path.")
            return
        }
        let planner = AXGuidePlanner()
        guard let plan = try? await planner.plan(goal: goal, snapshot: snapshot),
              let viewPlan = EverythingViewBuilder.build(plan: plan, snapshot: snapshot) else {
            speak("Nothing to draw there yet.")
            return
        }
        paint(everything: viewPlan, from: snapshot)
        speak("Here's the whole path, \(viewPlan.markers.count) steps.")
    }

    private func paint(everything viewPlan: EverythingViewPlan, from snapshot: AXSnapshot) {
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let overlays: [PerryGuidanceOverlay] = viewPlan.markers.map { marker in
            let point = AXCoordinateConverter.appKitPoint(
                axX: marker.position.x,
                axY: marker.position.y,
                primaryScreenMaxY: primaryMaxY,
                elementHeight: 24
            )
            return PerryGuidanceOverlay.scribble(
                points: [point, point],
                accentHex: "#34D399",
                lineWidth: 6,
                caption: "\(marker.number). \(marker.caption)",
                duration: 20
            )
        }
        overlayState.visualGuidanceOverlays.append(contentsOf: overlays)

        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            self?.overlayState.visualGuidanceOverlays.removeAll()
        }
    }

    private func present(step: GuideStep) {
        overlayState.taskBubbleText = step.instruction
        overlayState.animation = .waving
    }

    // MARK: Do mode

    func startDoing(goal: String) {
        Task { @MainActor in
            mode = .doing
            hidePanel()
            overlayState.animation = .running
            let runtime = makeRuntime()
            _ = await backgroundRunner.run(
                goal: goal,
                runtime: runtime,
                context: ScreenContext(frontAppBundleID: nil, frontWindowTitle: nil),
                targetWindow: nil
            )
            overlayState.animation = .idle
            mode = .idle
        }
    }

    private func makeRuntime() -> any AgentRuntime {
        CLIRuntime()
    }

    // MARK: Voice out

    private let synthesizer = AVSpeechSynthesizer()

    func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.5
        synthesizer.speak(utterance)
    }

    // MARK: Intent card confirmation

    func requestIntentApproval(card: IntentCard) async -> Bool {
        await withCheckedContinuation { continuation in
            let window = IntentCardWindow(card: card) { approved in
                continuation.resume(returning: approved)
            }
            intentCardWindow = window
            window.showNearCursor()
        }
    }

    // MARK: Dictation (STT)

    private lazy var dictation = DictationController { [weak self] transcript in
        self?.handleTranscript(transcript)
    }

    func beginDictation() {
        Task {
            let granted = await DictationController.requestPermission()
            guard granted else {
                speak("Allow microphone access and I'll listen.")
                return
            }
            overlayState.animation = .waiting
            do {
                try dictation.start()
                speak("Listening.")
            } catch {
                speak("Couldn't start listening: \(error.localizedDescription)")
            }
        }
    }

    func finishDictation() {
        dictation.finish()
        overlayState.animation = .idle
    }

    private func handleTranscript(_ text: String) {
        switch GuideIntentParser.parse(text) {
        case .guide(let goal):
            startGuiding(goal: goal)
        case .showEverything(let goal):
            Task { await showEverything(goal: goal) }
        case .doTask(let goal):
            startDoing(goal: goal)
        case .dismiss:
            dismiss()
        case .notAGuideRequest:
            startGuiding(goal: text)
        }
    }

    // MARK: Onboarding

    private func runOnboardingIfNeeded() {
        let snapshot = PerryPermissionSnapshot.probe()
        if !snapshot.allGranted {
            runOnboarding(force: false)
        }
    }

    func runOnboarding(force: Bool) {
        if onboardingFlow != nil && !force { return }
        let flow = OnboardingFlow()
        onboardingFlow = flow
        OnboardingWindow.show(flow: flow, controller: self)
    }

    // MARK: Interactive confirmer bridging supervisor → card

    func makeConfirmer() -> Confirmer {
        InteractiveConfirmer(controller: self)
    }
}

struct InteractiveConfirmer: Confirmer {
    weak var controller: AppController?

    func requestConfirmation(_ request: ConfirmationRequest) async -> Bool {
        guard let controller = await MainActor.run(body: { controller }) else { return false }
        let card = IntentCard(
            title: request.actionSummary,
            tier: request.tier,
            targetSummary: request.reason
        )
        return await controller.requestIntentApproval(card: card)
    }
}
