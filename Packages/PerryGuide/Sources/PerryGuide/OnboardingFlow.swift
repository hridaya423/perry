import Foundation
import PerryCore
import PerryCapture
import PerryRuntimes

/// PRD §4 Onboarding: permission walkthrough with why-we-need-it cards,
/// runtime auto-detect, guided demo offer, wake-word opt-in. Under two
/// minutes to first magic moment; this state machine sequences it.
public struct OnboardingStep: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case welcome
        case accessibilityPermission
        case screenRecordingPermission
        case microphonePermission
        /// Combined Accessibility + Screen Recording job — one card, two
        /// switches, both required before Perry can point or act.
        case screenAccess
        case runtimeDetect
        case guidedDemoOffer
        case memoryConsent
        case wakeWordOffer
        case done
    }

    public let id: Kind
    public let title: String
    public let body: String

    public init(_ kind: Kind, title: String, body: String) {
        self.id = kind
        self.title = title
        self.body = body
    }
}

public actor OnboardingFlow {
    private let steps: [OnboardingStep]
    private(set) public var index: Int = 0
    private(set) public var completed: Bool = false
    private let probe: @Sendable () async -> PerryPermissionSnapshot
    private let cliDetector: @Sendable () throws -> URL
    private let codexDetector: @Sendable () throws -> URL

    public init(
        probe: @escaping @Sendable () async -> PerryPermissionSnapshot = { await PerryPermissionSnapshot.probe() },
        cliDetector: @escaping @Sendable () throws -> URL = { try CLIRuntime.locateExecutable() },
        codexDetector: @escaping @Sendable () throws -> URL = { try CodexRuntime.bundledLocator() }
    ) {
        self.probe = probe
        self.cliDetector = cliDetector
        self.codexDetector = codexDetector

        let all: [OnboardingStep] = [
            OnboardingStep(.welcome, title: "Meet Perry",
                           body: "Perry works two ways. Guide: it points at the next thing to click so you learn as you go. Do: it carries out the task itself and reports exactly what it verified. Start either from the menu bar, a shortcut, or optional voice input."),
            OnboardingStep(.screenAccess, title: "Let Perry see your screen",
                           body: "Two switches, both needed. Accessibility lets Perry find buttons and fields by name. Screen Recording lets Perry look at an app when labels are missing — screenshots go only to the model provider you pick, under that provider's data policies. If a switch stays off, enable it in System Settings → Privacy & Security and choose Retry."),
            OnboardingStep(.runtimeDetect, title: "Verify the brain",
                           body: "Perry ships with its own Codex runtime and checks it's ready. Prefer your own model account? You can connect a provider in Settings — task context and screenshots go only to the route you choose, and Apple speech stays on this Mac."),
            OnboardingStep(.guidedDemoOffer, title: "See it work, for real",
                           body: "Circle a real area with ⌥⌘ and drag. Perry reads what's there, teaches two live Guide steps that advance when you click, then runs a safe task inside its private sandbox and reports the verified result."),
            OnboardingStep(.memoryConsent, title: "Choose what Perry remembers",
                           body: "Perry can save task context on this Mac to make later sessions more useful. Memory starts off, and you can inspect or erase it in Settings — this choice is optional."),
            OnboardingStep(.wakeWordOffer, title: "Wake word (off by default)",
                           body: "Say \"hey Perry\" to start talking — on-device listening, only when enabled. Most people just use the hotkey. Optional; skip it if you'd like."),
            OnboardingStep(.done, title: "You're set",
                           body: "Press ⌥⌘P whenever you want Perry — say \"guide me\" to learn or describe a task to hand off. Tasks you run in the background continue until they finish or you stop them."),
        ]
        self.steps = all
    }

    public func currentStep() -> OnboardingStep? {
        guard !completed else { return nil }
        return steps.indices.contains(index) ? steps[index] : nil
    }

    public func back() async -> OnboardingStep? {
        if completed {
            completed = false
            return currentStep()
        }
        guard index > 0 else { return currentStep() }

        let snapshot = await probe()
        while index > 0 {
            index -= 1
            if Self.grantStatus(of: steps[index], snapshot: snapshot) != true {
                break
            }
        }
        return currentStep()
    }

    /// Advances past the current step. A permission card the OS has already
    /// granted is skipped automatically, keeping reinstalls under two minutes.
    public func advance() async -> OnboardingStep? {
        if index < steps.count - 1 {
            index += 1
        } else {
            completed = true
            return nil
        }

        let snapshot = await probe()
        while index < steps.count,
              let grantStatus = Self.grantStatus(of: steps[index], snapshot: snapshot),
              grantStatus == true {
            index += 1
        }
        if index >= steps.count {
            completed = true
            return nil
        }
        return steps[index]
    }

    /// nil for non-permission steps; otherwise whether that permission is usable.
    private static func grantStatus(of step: OnboardingStep, snapshot: PerryPermissionSnapshot) -> Bool? {
        switch step.id {
        case .screenAccess:
            return snapshot.accessibility && snapshot.screenRecording.isUsable
        default: return nil
        }
    }

    public func detectedRuntimeSummary() -> String? {
        if let codex = try? codexDetector() {
            return "Codex (\(codex.lastPathComponent))"
        }
        do {
            return "Claude Code (\(try cliDetector().lastPathComponent))"
        } catch {
            return nil
        }
    }
}
