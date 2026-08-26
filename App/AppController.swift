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
    private var memoryMenuItem: NSMenuItem?

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
        SoundPlayer.warmUp()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWipeDataRequested),
            name: .perryWipeDataRequested,
            object: nil
        )
    }

    @objc private func handleWipeDataRequested() {
        Task { await wipeDataAction() }
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
        SoundPlayer.play(.wake)
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
        item.menu?.delegate = self
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

        let memoryItem = NSMenuItem(title: "Memory:…", action: #selector(toggleMemoryAction), keyEquivalent: "")
        memoryItem.target = self
        memoryMenuItem = memoryItem
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

    private func refreshMemoryMenuTitle() async {
        let current = await memoryStore.currentConfiguration()
        memoryMenuItem?.title = "Memory: \(current.enabled ? "on" : "off")"
    }

    @objc private func guidePromptAction() {
        wake()
        speak("What should I teach you?")
    }

    @objc private func everythingAction() {
        Task { await showEverything(goal: "walk through the frontmost window") }
    }

    @objc private func doPromptAction() {
        wake()
        speak("What are we taking off your hands?")
    }

    @objc private func toggleMemoryAction() {
        Task {
            let current = await memoryStore.currentConfiguration()
            await memoryStore.setConfiguration(MemoryConfiguration(enabled: !current.enabled))
            await refreshMemoryMenuTitle()
        }
    }

    @objc private func wipeDataAction() async {
        await memoryStore.wipe()
        await activityLog.wipe()
        speak("Memory and logs wiped.")
    }

    // MARK: Panel (the type/talk surface)

    private func showPanel() {
        if panel == nil {
            let host = NSHostingView(rootView: SessionPanelView(controller: self))
            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 340, height: 168),
                styleMask: [.titled, .nonactivatingPanel, .utilityWindow, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            p.contentView = host
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false
            p.isOpaque = false
            p.backgroundColor = .clear
            p.titlebarAppearsTransparent = true
            p.level = .floating
            panel = p
        }
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel?.setFrameOrigin(
                NSPoint(x: frame.maxX - 360, y: frame.minY + 140)
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
                SoundPlayer.play(.done)
                speak("That's the whole flow.")
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
                duration: Self.everythingPaintDuration
            )
        }
        overlayState.visualGuidanceOverlays.append(contentsOf: overlays)

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.everythingPaintDuration) { [weak self] in
            guard let self else { return }
            let paintedIDs = Set(overlays.map(\.id))
            self.overlayState.visualGuidanceOverlays.removeAll { paintedIDs.contains($0.id) }
        }
    }

    private static let everythingPaintDuration: TimeInterval = 20

    private func present(step: GuideStep) {
        overlayState.taskBubbleText = step.instruction
        overlayState.animation = .waving
    }

    // MARK: Do mode

    func startDoing(goal: String) {
        Task { @MainActor in
            mode = .doing
            hidePanel()
            SoundPlayer.play(.send)
            overlayState.animation = .running
            let runtime = makeRuntime()
            let confirmer = InteractiveConfirmer(controller: self)
            let supervisor = DoSupervisor(activityLog: activityLog, confirmer: confirmer)
            _ = await supervisor.run(
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
        let codex = CodexRuntime()
        do {
            _ = try CodexRuntime.bundledLocator()
            return codex
        } catch {
            return CLIRuntime()
        }
    }

    // MARK: Voice out

    private let synthesizer = AVSpeechSynthesizer()

    /// Prefer a downloaded enhanced/premium voice (free in System Settings >
    /// Accessibility > Spoken Content); fall back to whatever en-US exists.
    static let speakingVoice: AVSpeechSynthesisVoice? = {
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        return english.first { $0.quality == .premium }
            ?? english.first { $0.quality == .enhanced }
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }()

    static func speakingVoiceDisplayName() -> String? {
        speakingVoice?.name
    }

    func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.speakingVoice
        utterance.rate = 0.52
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
    private let wakeWordGate = WakeWordGate(enabled: UserDefaults.standard.object(forKey: "perry.wakeWord.enabled") as? Bool ?? false)

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
        if let command = wakeWordGate.match(inTranscript: text) {
            speak("Wake word heard.")
            dispatch(commandText: command.isEmpty ? nil : command)
            return
        }
        dispatch(commandText: text)
    }

    private func dispatch(commandText: String?) {
        guard let text = commandText, !text.isEmpty else {
            showPanel()
            return
        }
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

extension AppController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        Task { await refreshMemoryMenuTitle() }
    }
}

struct InteractiveConfirmer: Confirmer {
    weak var controller: AppController?

    func requestConfirmation(_ request: ConfirmationRequest) async -> Bool {
        guard let controller = await MainActor.run(body: { controller }) else { return false }
        let card = IntentCard(
            title: "About to \(request.actionSummary)",
            tier: request.tier,
            targetSummary: request.reason
        )
        SoundPlayer.play(.receive)
        return await controller.requestIntentApproval(card: card)
    }
}
