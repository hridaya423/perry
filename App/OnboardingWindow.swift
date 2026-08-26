import AppKit
import SwiftUI
import PerryGuide

/// Onboarding window driving OnboardingFlow with real permission requests.
final class OnboardingWindow: NSPanel {
    static var active: OnboardingWindow?

    static func show(flow: OnboardingFlow, controller: AppController) {
        active?.close()
        let window = OnboardingWindow(flow: flow, controller: controller)
        active = window
        if let screen = NSScreen.main?.visibleFrame {
            window.setFrameOrigin(
                NSPoint(x: screen.midX - 220, y: screen.midY - 200)
            )
        }
        window.orderFrontRegardless()
    }

    init(flow: OnboardingFlow, controller: AppController) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 380),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        contentView = NSHostingView(
            rootView: OnboardingView(flow: flow, controller: controller) {
                Self.active?.close()
                Self.active = nil
            }
        )
    }
}

struct OnboardingView: View {
    @State private var currentStep: OnboardingStep?
    @State private var runtimeSummary: String?
    let flow: OnboardingFlow
    let controller: AppController
    let onFinish: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let step = currentStep {
                Text(step.title)
                    .font(.title3.bold())
                Text(step.body)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if step.id == .runtimeDetect {
                    if let summary = runtimeSummary {
                        Label("Found: \(summary)", systemImage: "checkmark.circle")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.green)
                    } else {
                        Label("No coding-agent CLI found yet", systemImage: "magnifyingglass")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                HStack {
                    if step.id == .microphonePermission || step.id == .screenRecordingPermission || step.id == .accessibilityPermission {
                        Button("Grant in System Settings") {
                            PermissionRequester.openSettings(for: step.id)
                        }
                    }
                    Spacer()
                    Button(currentStep?.id == .done ? "Finish" : "Continue") {
                        advance()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Text("You're set.")
                    .font(.title3.bold())
            }
        }
        .padding(22)
        .task {
            currentStep = await flow.currentStep()
            runtimeSummary = await flow.detectedRuntimeSummary()
        }
    }

    private func advance() {
        Task { @MainActor in
            // Request OS prompts at the right steps before advancing.
            if let id = currentStep?.id {
                _ = await PermissionRequester.requestIfNeeded(id)
            }
            currentStep = await flow.advance()
            if currentStep == nil {
                onFinish()
            } else if currentStep?.id == .runtimeDetect {
                runtimeSummary = await flow.detectedRuntimeSummary()
            }
        }
    }
}

enum PermissionRequester {
    static func requestIfNeeded(_ kind: OnboardingStep.Kind) async -> Bool {
        switch kind {
        case .microphonePermission:
            return await DictationController.requestPermission()
        default:
            return false
        }
    }

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
