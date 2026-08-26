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
        case runtimeDetect
        case guidedDemoOffer
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
    private let probe: @Sendable () -> PerryPermissionSnapshot
    private let cliDetector: @Sendable () throws -> URL

    public init(
        probe: @escaping @Sendable () -> PerryPermissionSnapshot = { PerryPermissionSnapshot.probe() },
        cliDetector: @escaping @Sendable () throws -> URL = { try CLIRuntime.locateExecutable() }
    ) {
        self.probe = probe
        self.cliDetector = cliDetector

        let all: [OnboardingStep] = [
            OnboardingStep(.welcome, title: "Meet Perry",
                           body: "Perry points at things on your screen to teach you, and can take whole tasks off your hands. Nothing happens until you press the hotkey."),
            OnboardingStep(.accessibilityPermission, title: "See where things are",
                           body: "Accessibility access lets Perry find buttons and fields by name so it can point precisely. Your screen contents stay on this Mac."),
            OnboardingStep(.screenRecordingPermission, title: "Understand your apps visually",
                           body: "Screen recording lets Perry read what an app looks like when there are no labels — like canvas tools. Screenshots live in memory only during a session and are never saved or synced."),
            OnboardingStep(.microphonePermission, title: "Talk instead of type (optional)",
                           body: "Microphone access powers voice input using Apple's on-device speech recognition. Skip this if you'd rather type."),
            OnboardingStep(.runtimeDetect, title: "Pick a brain",
                           body: "Perry works best with a coding-agent CLI you already have. We'll check what's installed."),
            OnboardingStep(.guidedDemoOffer, title: "Try one thing",
                           body: "Let's have Perry rename three files in Finder. You'll see how guiding feels."),
            OnboardingStep(.wakeWordOffer, title: "Wake word (off by default)",
                           body: "Say \"hey Perry\" to start talking. It uses on-device listening only when enabled here. Most people just use the hotkey."),
            OnboardingStep(.done, title: "You're set",
                           body: "Press the hotkey anywhere. Perry never watches between sessions."),
        ]
        self.steps = all
    }

    public func currentStep() -> OnboardingStep? {
        guard !completed else { return nil }
        return steps.indices.contains(index) ? steps[index] : nil
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

        let snapshot = probe()
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
        case .accessibilityPermission: return snapshot.accessibility
        case .screenRecordingPermission: return snapshot.screenRecording.isUsable
        case .microphonePermission: return snapshot.microphone.isUsable
        default: return nil
        }
    }

    public func detectedRuntimeSummary() -> String? {
        do {
            return try cliDetector().lastPathComponent
        } catch {
            return nil
        }
    }
}
