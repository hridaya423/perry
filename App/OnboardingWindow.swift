import AppKit
import SwiftUI
import PerryCapture
import PerryGuide

enum OnboardingRuntimeState: Equatable {
    case checking
    case unavailable
    case available(String)

    init(summary: String?) {
        if let summary {
            self = .available(summary)
        } else {
            self = .unavailable
        }
    }

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

enum OnboardingReadiness: Equatable {
    case ready
    case missingPermissions
    case missingRuntime

    init(snapshot: PerryPermissionSnapshot?, runtime: OnboardingRuntimeState) {
        guard snapshot?.requiredPermissionsGranted == true else {
            self = .missingPermissions
            return
        }
        self = runtime.isAvailable ? .ready : .missingRuntime
    }
}

/// Onboarding window driving OnboardingFlow with real permission requests.
@MainActor
final class OnboardingWindow: NSPanel {
    static var active: OnboardingWindow?
    private var closeHandler: (() -> Void)?

    override var canBecomeKey: Bool { true }

    static func show(
        flow: OnboardingFlow,
        controller: AppController,
        onClose: @escaping () -> Void = {},
        onFinish: @escaping () -> Void = {},
        permissionProbe: @escaping () async -> PerryPermissionSnapshot = { await PerryPermissionSnapshot.probe() }
    ) {
        active?.closeHandler = nil
        active?.close()
        let window = OnboardingWindow(
            flow: flow,
            controller: controller,
            onClose: onClose,
            onFinish: onFinish,
            permissionProbe: permissionProbe
        )
        active = window
        if let screen = NSScreen.main?.visibleFrame {
            window.setFrameOrigin(
                NSPoint(x: screen.midX - window.frame.width / 2, y: screen.midY - window.frame.height / 2)
            )
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    init(
        flow: OnboardingFlow,
        controller: AppController,
        onClose: @escaping () -> Void = {},
        onFinish: @escaping () -> Void = {},
        permissionProbe: @escaping () async -> PerryPermissionSnapshot = { await PerryPermissionSnapshot.probe() }
    ) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        title = "Perry onboarding"
        isFloatingPanel = true
        level = .floating
        becomesKeyOnlyIfNeeded = false
        minSize = NSSize(width: 440, height: 380)
        closeHandler = onClose
#if DEBUG
        let onboardingView = OnboardingView(
            flow: flow,
            controller: controller,
            onFinish: {
                Self.active?.close()
                Self.active = nil
                onFinish()
            },
            permissionProbe: permissionProbe
        )
        let rootView = PerryDebugTextScale(arguments: ProcessInfo.processInfo.arguments).apply(to: onboardingView)
#else
        let rootView = OnboardingView(
            flow: flow,
            controller: controller,
            onFinish: {
                Self.active?.close()
                Self.active = nil
                onFinish()
            },
            permissionProbe: permissionProbe
        )
#endif
        contentView = NSHostingView(
            rootView: rootView
        )
    }

    override func close() {
        Self.active = nil
        let handler = closeHandler
        closeHandler = nil
        super.close()
        handler?()
    }
}

struct OnboardingView: View {
    @State private var currentStep: OnboardingStep?
    @State private var currentIndex = 0
    @State private var runtimeState: OnboardingRuntimeState = .checking
    @State private var permissionSnapshot: PerryPermissionSnapshot?
    @State private var isLoading = true
    @State private var isProbing = false
    @State private var isAdvancing = false
    @State private var flowCompleted = false
    @State private var memoryEnabled = false
    @State private var wakeWordEnabled = false
    let flow: OnboardingFlow
    let controller: AppController
    let onFinish: () -> Void
    let permissionProbe: () async -> PerryPermissionSnapshot

    private static let stepCount = 7

    init(
        flow: OnboardingFlow,
        controller: AppController,
        onFinish: @escaping () -> Void,
        permissionProbe: @escaping () async -> PerryPermissionSnapshot = { await PerryPermissionSnapshot.probe() }
    ) {
        self.flow = flow
        self.controller = controller
        self.onFinish = onFinish
        self.permissionProbe = permissionProbe
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isLoading {
                ProgressView("Checking Perry setup…")
                    .accessibilityLabel("Checking Perry setup")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                progressHeader

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let step = currentStep {
                            stepContent(step)
                        } else {
                            completionContent
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.vertical, 2)
                }
                .accessibilityIdentifier("onboarding.content")
                .scrollIndicators(.automatic)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                footer
            }
        }
        .padding(22)
        .frame(minWidth: 440, maxWidth: .infinity, minHeight: 380, maxHeight: .infinity, alignment: .topLeading)
        .task {
            await load()
        }
    }

    private var progressHeader: some View {
        let displayedIndex = min(currentIndex + 1, Self.stepCount)
        return HStack(spacing: 10) {
            Text("Step \(displayedIndex) of \(Self.stepCount)")
                .font(PerryTheme.Typography.mono.weight(.medium))
                .foregroundStyle(.secondary)
            ProgressView(value: Double(displayedIndex), total: Double(Self.stepCount))
                .progressViewStyle(.linear)
                .frame(maxWidth: 160)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Onboarding progress")
        .accessibilityValue("Step \(displayedIndex) of \(Self.stepCount)")
    }

    @ViewBuilder
    private func stepContent(_ step: OnboardingStep) -> some View {
        Text(step.title)
            .font(.title3.bold())
            .accessibilityAddTraits(.isHeader)
        Text(step.body)
            .font(.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        if step.id == .runtimeDetect {
            switch runtimeState {
            case .checking:
                Label("Checking for a coding-agent CLI…", systemImage: "magnifyingglass")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Checking for a coding-agent CLI")
            case .available(let summary):
                Label("Found: \(summary)", systemImage: "checkmark.circle")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(PerryTheme.Colors.success)
            case .unavailable:
                Label("No coding-agent CLI found yet", systemImage: "magnifyingglass")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button("Use your own provider") {
                controller.openSettings(tab: .runtimes)
            }
            .accessibilityHint("Open Settings to connect your own model account")
        }

        if step.id == .screenAccess {
            screenAccessStatus
        }

        if step.id == .done, let result = controller.demoVerifiedSummary {
            Label("Verified: \(result)", systemImage: "checkmark.seal")
                .font(.callout.weight(.medium))
                .foregroundStyle(PerryTheme.Colors.success)
                .accessibilityLabel("Demo result")
                .accessibilityValue(result)
        }

        if step.id == .memoryConsent {
            Toggle("Remember useful context between sessions", isOn: $memoryEnabled)
                .accessibilityHint("Stores task memory locally on this Mac")
            Text(memoryEnabled ? "Perry will save local task memory. You can inspect or erase it at any time." : "Perry will not save task memory between sessions.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        if step.id == .wakeWordOffer {
            Toggle("Listen for \"hey Perry\"", isOn: $wakeWordEnabled)
                .accessibilityHint("Keeps the microphone active with a visible menu bar indicator")
            Text(wakeWordEnabled ? "The menu bar icon stays active while Perry is listening. Turn this off any time in Settings." : "Use the global hotkey when you want Perry. The microphone stays inactive between sessions.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Two required switches on one card — each names its benefit and its own
    /// recovery, per the grant-in-context job.
    @ViewBuilder
    private var screenAccessStatus: some View {
        ForEach([OnboardingStep.Kind.accessibilityPermission, .screenRecordingPermission], id: \.self) { kind in
            let granted = permissionSnapshot.map { OnboardingPermissions.isGranted(kind, in: $0) } ?? false
            HStack(spacing: PerryTheme.Spacing.control) {
                Label(kind == .accessibilityPermission ? "Accessibility — finds buttons by name" : "Screen Recording — sees apps without labels",
                      systemImage: granted ? "checkmark.circle" : "lock.circle")
                    .font(.callout)
                    .foregroundStyle(granted ? PerryTheme.Colors.success : .secondary)
                Spacer(minLength: 4)
                if !granted {
                    Button("Grant") {
                        PermissionRequester.openSettings(for: kind)
                    }
                    .controlSize(.small)
                    .accessibilityLabel("Grant \(kind == .accessibilityPermission ? "Accessibility" : "Screen Recording")")
                    .accessibilityHint("Open System Settings to change this permission")
                }
            }
        }
    }

    private var completionContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch readiness {
            case .ready:
                Text("You're set.")
                    .font(.title3.bold())
                Text("Use the hotkey or menu bar to start a request. Tasks you run in the background continue until they finish or you stop them.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Button {
                    onFinish()
                    controller.startDemonstrationRecording()
                } label: {
                    Label("Teach Perry a task — record a demonstration", systemImage: "circle.dotted")
                }
                .buttonStyle(.link)
                .accessibilityHint("Finish onboarding and start a Watch & Learn recording you can stop anytime")
            case .missingPermissions:
                Text("Perry still needs access.")
                    .font(.title3.bold())
                Text("Accessibility and Screen Recording are required before Perry can guide or act on your screen.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Label("Enable both permissions in System Settings, then choose Retry.", systemImage: "lock.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .missingRuntime:
                Text("Perry still needs a runtime.")
                    .font(.title3.bold())
                Text("Perry couldn't verify its bundled Codex runtime. Choose Retry. If this continues, reinstall Perry.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(alignment: .center, spacing: 10) {
            if canGoBack {
                Button {
                    goBack()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .accessibilityLabel("Back")
                .accessibilityHint("Return to the previous onboarding step")
            }

            Spacer(minLength: 8)

            if let step = currentStep {
                if OnboardingPermissions.isPermissionStep(step.id) {
                    Button("Retry", action: retry)
                        .accessibilityLabel("Retry")
                        .accessibilityHint("Check these permissions again")
                        .disabled(isProbing || isAdvancing)
                } else if step.id == .runtimeDetect {
                    Button("Retry", action: retry)
                        .accessibilityLabel("Retry")
                        .accessibilityHint("Check for an installed coding-agent CLI again")
                        .disabled(isProbing || isAdvancing)
                }

                if step.id == .guidedDemoOffer {
                    Button("Try the live demo") {
                        controller.runFlagshipDemo { succeeded in
                            if succeeded { advance() }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }

                if step.id == .memoryConsent || step.id == .wakeWordOffer {
                    Button("Not now") { advance(applyChoice: false) }
                        .accessibilityHint("Skip this optional choice")
                        .disabled(isAdvancing)
                }

                if step.id == .guidedDemoOffer {
                    Button("Continue", action: advance)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.bordered)
                        .disabled(!canContinue)
                } else {
                    Button(step.id == .done ? "Finish" : "Continue", action: advance)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canContinue)
                }
            } else if flowCompleted {
                Button("Retry", action: retry)
                    .accessibilityLabel("Retry")
                    .accessibilityHint("Check required permissions again")
                    .disabled(isProbing || isAdvancing)
            }
        }
    }

    private var canGoBack: Bool {
        !isLoading && !isProbing && !isAdvancing && currentIndex > 0
    }

    private var readiness: OnboardingReadiness {
        OnboardingReadiness(snapshot: permissionSnapshot, runtime: runtimeState)
    }

    private var canContinue: Bool {
        guard !isLoading, !isProbing, !isAdvancing, let step = currentStep else { return false }
        switch step.id {
        case .screenAccess:
            guard let permissionSnapshot else { return false }
            return permissionSnapshot.accessibility && permissionSnapshot.screenRecording.isUsable
        case .runtimeDetect:
            return runtimeState.isAvailable
        case .guidedDemoOffer, .memoryConsent, .wakeWordOffer:
            return permissionSnapshot?.requiredPermissionsGranted == true
        case .done:
            return readiness == .ready
        case .welcome, .accessibilityPermission, .screenRecordingPermission, .microphonePermission:
            return true
        }
    }

    private func load() async {
        let step = await flow.currentStep()
        let index = await flow.index
        let completed = await flow.completed
        let snapshot = await permissionProbe()
        var summary: String?
        if step?.id == .runtimeDetect {
            summary = await flow.detectedRuntimeSummary()
        }
        guard !Task.isCancelled else { return }
        currentStep = step
        currentIndex = index
        flowCompleted = completed
        permissionSnapshot = snapshot
        runtimeState = OnboardingRuntimeState(summary: summary)
        let memoryConfiguration = await controller.currentMemoryConfiguration()
        memoryEnabled = memoryConfiguration.enabled
        wakeWordEnabled = UserDefaults.standard.bool(forKey: "perry.wakeWord.enabled")
        isLoading = false
    }

    private func retry() {
        guard !isLoading, !isProbing, !isAdvancing else { return }
        isProbing = true
        if currentStep?.id == .runtimeDetect {
            runtimeState = .checking
            Task { @MainActor in
                let summary = await flow.detectedRuntimeSummary()
                guard !Task.isCancelled else { return }
                runtimeState = OnboardingRuntimeState(summary: summary)
                isProbing = false
            }
        } else {
            Task { @MainActor in
                let snapshot = await permissionProbe()
                guard !Task.isCancelled else { return }
                permissionSnapshot = snapshot
                isProbing = false
                if currentStep == nil, flowCompleted, readiness == .ready {
                    onFinish()
                }
            }
        }
    }

    private func goBack() {
        guard canGoBack else { return }
        isAdvancing = true
        Task { @MainActor in
            let previous = await flow.back()
            let index = await flow.index
            let completed = await flow.completed
            let snapshot = await permissionProbe()
            var summary: String?
            if previous?.id == .runtimeDetect {
                summary = await flow.detectedRuntimeSummary()
            }
            guard !Task.isCancelled else { return }
            currentStep = previous
            currentIndex = index
            flowCompleted = completed
            permissionSnapshot = snapshot
            if previous?.id == .runtimeDetect {
                runtimeState = OnboardingRuntimeState(summary: summary)
            }
            isAdvancing = false
        }
    }

    private func advance() {
        advance(applyChoice: true)
    }

    /// `applyChoice: false` skips an optional post-activation choice without
    /// persisting whatever the toggle currently shows.
    private func advance(applyChoice: Bool) {
        guard canContinue, let step = currentStep else { return }
        isAdvancing = true
        Task { @MainActor in
            if applyChoice {
                if step.id == .memoryConsent {
                    await controller.setMemoryEnabled(memoryEnabled)
                }
                if step.id == .wakeWordOffer {
                    controller.voice.updateWakeWordEnabled(wakeWordEnabled)
                }
            }

            let next = await flow.advance()
            let index = await flow.index
            if next == nil {
                let snapshot = await permissionProbe()
                currentStep = nil
                currentIndex = index
                flowCompleted = true
                permissionSnapshot = snapshot
                isAdvancing = false
                if readiness == .ready {
                    onFinish()
                }
                return
            }

            let snapshot = await permissionProbe()
            var summary: String?
            if next?.id == .runtimeDetect {
                summary = await flow.detectedRuntimeSummary()
            }
            guard !Task.isCancelled else { return }
            currentStep = next
            currentIndex = index
            flowCompleted = false
            permissionSnapshot = snapshot
            if next?.id == .runtimeDetect {
                runtimeState = OnboardingRuntimeState(summary: summary)
            }
            isAdvancing = false
        }
    }
}

enum OnboardingPermissions {
    static func isPermissionStep(_ kind: OnboardingStep.Kind) -> Bool {
        kind == .screenAccess
    }

    static func isGranted(_ kind: OnboardingStep.Kind, in snapshot: PerryPermissionSnapshot) -> Bool {
        switch kind {
        case .accessibilityPermission:
            return snapshot.accessibility
        case .screenRecordingPermission:
            return snapshot.screenRecording.isUsable
        case .screenAccess:
            return snapshot.accessibility && snapshot.screenRecording.isUsable
        default:
            return true
        }
    }
}

enum PermissionRequester {
    static func openSettings(for kind: OnboardingStep.Kind) {
        let pane: String
        switch kind {
        case .accessibilityPermission:
            pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .screenRecordingPermission:
            pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .microphonePermission:
            pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        default:
            return
        }
        if let url = URL(string: pane) {
            NSWorkspace.shared.open(url)
        }
    }
}
