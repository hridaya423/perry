import AppKit
import XCTest
import PerryCapture
import PerryGuide
@testable import Perry

@MainActor
final class OnboardingWindowTests: XCTestCase {
    func testWindowCanBecomeKeyAndResize() {
        let window = OnboardingWindow(
            flow: OnboardingFlow(),
            controller: AppController(),
            onFinish: {}
        )
        defer { window.close() }

        XCTAssertTrue(window.canBecomeKey)
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertGreaterThanOrEqual(window.minSize.width, 440)
        XCTAssertGreaterThanOrEqual(window.minSize.height, 380)
    }

    func testRequiredPermissionGateDoesNotTreatDeniedAccessAsGranted() {
        let snapshot = PerryPermissionSnapshot(
            accessibility: false,
            screenRecording: .denied,
            microphone: .denied
        )

        XCTAssertFalse(OnboardingPermissions.isGranted(.accessibilityPermission, in: snapshot))
        XCTAssertFalse(OnboardingPermissions.isGranted(.screenRecordingPermission, in: snapshot))
        XCTAssertFalse(OnboardingPermissions.isGranted(.screenAccess, in: snapshot))
    }

    func testScreenAccessIsGrantedOnlyWhenBothRequiredPermissionsAreUsable() {
        let base = PerryPermissionSnapshot(
            accessibility: false,
            screenRecording: .granted,
            microphone: .denied
        )
        XCTAssertFalse(OnboardingPermissions.isGranted(.screenAccess, in: base))
        XCTAssertTrue(OnboardingPermissions.isGranted(
            .screenAccess,
            in: PerryPermissionSnapshot(accessibility: true, screenRecording: .granted, microphone: .denied)
        ))
    }

    func testRuntimeStateCannotBeAvailableWithoutAProbeResult() {
        XCTAssertEqual(OnboardingRuntimeState(summary: nil), .unavailable)
        XCTAssertFalse(OnboardingRuntimeState(summary: nil).isAvailable)
        XCTAssertEqual(OnboardingRuntimeState(summary: "Codex (codex)"), .available("Codex (codex)"))
        XCTAssertTrue(OnboardingRuntimeState(summary: "Codex (codex)").isAvailable)
    }

    func testReadinessRequiresPermissionsAndAnAvailableRuntime() {
        let granted = PerryPermissionSnapshot(
            accessibility: true,
            screenRecording: .granted,
            microphone: .denied
        )
        let denied = PerryPermissionSnapshot(
            accessibility: false,
            screenRecording: .denied,
            microphone: .granted
        )

        XCTAssertEqual(
            OnboardingReadiness(snapshot: granted, runtime: .available("Codex (codex)")),
            .ready
        )
        XCTAssertEqual(
            OnboardingReadiness(snapshot: denied, runtime: .available("Codex (codex)")),
            .missingPermissions
        )
        XCTAssertEqual(
            OnboardingReadiness(snapshot: granted, runtime: .unavailable),
            .missingRuntime
        )
    }

    func testClosingWindowReleasesOnboardingOwnershipWithoutCompleting() {
        var closeCount = 0
        var finishCount = 0
        let window = OnboardingWindow(
            flow: OnboardingFlow(),
            controller: AppController(),
            onClose: { closeCount += 1 },
            onFinish: { finishCount += 1 }
        )

        window.close()
        window.close()

        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(finishCount, 0)
    }

    func testIntentCardCanBecomeKeyForKeyboardConfirmation() {
        let window = IntentCardWindow(
            card: IntentCard(
                title: "About to delete a file",
                tier: .red,
                targetSummary: "Finder · Desktop"
            ),
            completion: { _ in }
        )
        defer { window.cancel() }

        window.showNearCursor()

        XCTAssertTrue(window.canBecomeKey)
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertGreaterThanOrEqual(window.minSize.width, 388)
        XCTAssertGreaterThanOrEqual(window.minSize.height, 240)
        XCTAssertFalse(window.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(window.isVisible)
    }

    func testCancellingApprovalTaskClosesItsPromptAndReturnsFalse() async throws {
        let session = SessionController()
        try session.wake()
        try session.startExecution(ExecutionSessionState(
            taskID: UUID(),
            goal: "approval cancellation fixture",
            startedAt: Date(),
            appBundleID: nil,
            workspace: URL(fileURLWithPath: "/tmp/perry-approval-fixture"),
            lifecycle: .starting
        ))
        try session.setExecutionPhase(.running)
        let approvalID = UUID()
        try session.awaitApproval(approvalID)
        let controller = AppController(sessionController: session)
        let finished = expectation(description: "approval cancellation returned")
        let request = Task { @MainActor in
            let approved = await controller.requestIntentApproval(
                id: approvalID,
                card: IntentCard(title: "Test approval", tier: .orange, targetSummary: "No action will run")
            )
            finished.fulfill()
            return approved
        }
        var prompt: IntentCardWindow?
        for _ in 0..<50 {
            prompt = NSApp.windows.compactMap { $0 as? IntentCardWindow }
                .first { $0.approvalID == approvalID && $0.isVisible }
            if prompt != nil { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(prompt)

        request.cancel()
        await fulfillment(of: [finished], timeout: 0.5)
        let remainedVisible = prompt?.isVisible
        prompt?.cancel()
        let approved = await request.value

        XCTAssertFalse(approved)
        XCTAssertEqual(remainedVisible, false)
    }
}
