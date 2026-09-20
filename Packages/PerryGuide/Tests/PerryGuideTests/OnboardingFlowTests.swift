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
            [.welcome, .screenAccess, .runtimeDetect, .guidedDemoOffer, .memoryConsent, .wakeWordOffer, .done]
        )
    }

    func testAllGrantedSkipsPermissionCards() async {
        let flow = OnboardingFlow(probe: { self.allGranted })
        _ = await flow.advance() // welcome

        let afterWelcome = await flow.currentStep()
        XCTAssertEqual(afterWelcome?.id, .runtimeDetect)
    }

    func testPermissionExplanationsDiscloseExternalProcessing() async {
        let flow = OnboardingFlow(probe: { self.nothingGranted })
        var explanations: [OnboardingStep.Kind: String] = [:]
        while let step = await flow.currentStep() {
            explanations[step.id] = step.body
            _ = await flow.advance()
        }

        XCTAssertTrue(explanations[.screenAccess]?.contains("model provider") == true)
        XCTAssertTrue(explanations[.screenAccess]?.contains("screenshots") == true)
        XCTAssertTrue(explanations[.runtimeDetect]?.contains("provider") == true)
        XCTAssertTrue(explanations[.runtimeDetect]?.contains("stays on this Mac") == true)
    }

    func testPartialGrantsKeepPermissionSteps() async {
        for denied in [
            PerryPermissionSnapshot(accessibility: true, screenRecording: .denied, microphone: .granted),
            PerryPermissionSnapshot(accessibility: false, screenRecording: .granted, microphone: .granted),
        ] {
            let flow = OnboardingFlow(probe: { denied })
            _ = await flow.advance() // welcome

            let next = await flow.currentStep()
            XCTAssertEqual(next?.id, .screenAccess)
        }
    }

    func testRuntimeDetectionReportsInstalledCLINameOrNull() async {
        let flow = OnboardingFlow(
            probe: { self.allGranted },
            cliDetector: { URL(fileURLWithPath: "/opt/homebrew/bin/claude") },
            codexDetector: { throw CLIUnavailableError(searchedPaths: ["/bundled/codex"]) }
        )
        let summary = await flow.detectedRuntimeSummary()
        XCTAssertEqual(summary, "Claude Code (claude)")

        let noneFlow = OnboardingFlow(
            probe: { self.allGranted },
            cliDetector: { throw CLIUnavailableError(searchedPaths: ["/x"]) },
            codexDetector: { throw CLIUnavailableError(searchedPaths: ["/bundled/codex"]) }
        )
        let missing = await noneFlow.detectedRuntimeSummary()
        XCTAssertNil(missing)
    }

    func testBackReturnsToThePreviousStep() async {
        let flow = OnboardingFlow(probe: { self.nothingGranted })
        _ = await flow.advance()

        let previous = await flow.back()
        let index = await flow.index

        XCTAssertEqual(previous?.id, .welcome)
        XCTAssertEqual(index, 0)
    }

    func testBackSkipsPermissionStepsThatAdvanceSkipped() async {
        let flow = OnboardingFlow(probe: { self.allGranted })
        _ = await flow.advance()

        let current = await flow.currentStep()
        let previous = await flow.back()

        XCTAssertEqual(current?.id, .runtimeDetect)
        XCTAssertEqual(previous?.id, .welcome)
    }
}
