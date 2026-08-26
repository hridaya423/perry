import XCTest
@testable import PerryGuide
import PerryCapture
import PerryRuntimes

final class OnboardingFlowTests: XCTestCase {
    private let allGranted = PerryPermissionSnapshot(
        accessibility: true,
        screenRecording: .granted,
        microphone: .granted
    )

    private let nothingGranted = PerryPermissionSnapshot(
        accessibility: false,
        screenRecording: .notDetermined,
        microphone: .notDetermined
    )

    func testSequenceWalksEveryStepInOrderWhenNothingGranted() async {
        let flow = OnboardingFlow(probe: { self.nothingGranted })
        var visited: [OnboardingStep.Kind] = []

        while let step = await flow.currentStep() {
            visited.append(step.id)
            _ = await flow.advance()
        }
        XCTAssertEqual(
            visited,
            [.welcome, .accessibilityPermission, .screenRecordingPermission, .microphonePermission, .runtimeDetect, .guidedDemoOffer, .wakeWordOffer, .done]
        )
    }

    func testAllGrantedSkipsPermissionCards() async {
        let flow = OnboardingFlow(probe: { self.allGranted })
        _ = await flow.advance() // welcome

        let afterWelcome = await flow.currentStep()
        XCTAssertEqual(afterWelcome?.id, .runtimeDetect)
    }

    func testPartialGrantsKeepPermissionSteps() async {
        let partial = PerryPermissionSnapshot(
            accessibility: true,
            screenRecording: .denied,
            microphone: .granted
        )
        let flow = OnboardingFlow(probe: { partial })
        _ = await flow.advance() // welcome

        let next = await flow.currentStep()
        XCTAssertEqual(next?.id, .screenRecordingPermission)
    }

    func testRuntimeDetectionReportsInstalledCLINameOrNull() async {
        let flow = OnboardingFlow(probe: { self.allGranted }, cliDetector: { URL(fileURLWithPath: "/opt/homebrew/bin/claude") })
        let summary = await flow.detectedRuntimeSummary()
        XCTAssertEqual(summary, "claude")

        let noneFlow = OnboardingFlow(probe: { self.allGranted }, cliDetector: { throw CLIUnavailableError(searchedPaths: ["/x"]) })
        let missing = await noneFlow.detectedRuntimeSummary()
        XCTAssertNil(missing)
    }
}
