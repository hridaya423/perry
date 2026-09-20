import Foundation
import XCTest

/// Drives every `DebugStateFixture` through `--perry-debug-state` and records a
/// screenshot plus the accessibility tree for review. These fixtures are
/// DEBUG-only; live TCC/Cua coverage stays in the separate live suites.
final class DebugStateFixtureUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-perry.onboarding.completed", "YES"]
    }

    override func tearDown() {
        app.terminate()
        app = nil
    }

    private struct PanelFixture {
        let name: String
        let status: String
        let expectActiveControls: Bool
    }

    private let panelFixtures: [PanelFixture] = [
        PanelFixture(name: "loading", status: "Reading the screen before I answer…", expectActiveControls: false),
        PanelFixture(name: "empty", status: "Press ⌥⌘P when you want Perry.", expectActiveControls: false),
        PanelFixture(name: "runtime-missing", status: "Perry can't find a usable runtime. Open Settings → Runtimes to install or repair one.", expectActiveControls: false),
        PanelFixture(name: "planning", status: "Planning the first safe step…", expectActiveControls: true),
        PanelFixture(name: "running", status: "Working: 2 of 5 steps done.", expectActiveControls: true),
        PanelFixture(name: "paused", status: "Paused — resume when you're ready.", expectActiveControls: true),
        PanelFixture(name: "verified", status: "Verified: both files moved and contents unchanged.", expectActiveControls: false),
        PanelFixture(name: "unverified", status: "Finished, but I couldn't verify the result — check before relying on it.", expectActiveControls: false),
        PanelFixture(name: "failed", status: "Stopped: the target window closed before the second step.", expectActiveControls: false),
        PanelFixture(name: "recovered", status: "Recovered the interrupted task after relaunch; no step replayed.", expectActiveControls: false),
        PanelFixture(name: "erased", status: "All Perry data erased.", expectActiveControls: false),
    ]

    func testPanelFixturesPresentExpectedStates() {
        for fixture in panelFixtures {
            app.launchArguments = [
                "-perry.onboarding.completed", "YES",
                "--perry-debug-state", fixture.name,
            ]
            app.launch()

            let window = app.windows.firstMatch
            XCTAssertTrue(window.waitForExistence(timeout: 5), "\(fixture.name): no window")

            let sessionStatus = window.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", "Session status")).firstMatch
            XCTAssertTrue(sessionStatus.waitForExistence(timeout: 5), "\(fixture.name): missing session status")
            XCTAssertEqual(sessionStatus.value as? String, fixture.status, fixture.name)

            let steering = window.textFields["Next-step direction"]
            XCTAssertFalse(steering.exists, "\(fixture.name): steering lives in the status strip, not the panel")
            let stripPointer = window.staticTexts["Pause, steer, or stop from the status strip."]
            XCTAssertEqual(stripPointer.exists, fixture.expectActiveControls, "\(fixture.name): status-strip pointer visibility")

            record(name: fixture.name)
            app.terminate()
        }
    }

    func testOrangeApprovalFixturePresentsApproveAndStop() {
        launch(fixture: "approval-orange")
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertTrue(window.staticTexts["About to move 2 files into Archive"].waitForExistence(timeout: 2))
        XCTAssertTrue(window.buttons["Move 2 files into Archive"].exists)
        XCTAssertTrue(window.buttons["Stop"].exists)
        record(name: "approval-orange")
    }

    func testRedApprovalFixtureRequiresTypedConfirmation() {
        launch(fixture: "approval-red")
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertTrue(window.staticTexts["About to empty the Trash"].waitForExistence(timeout: 2))
        let approve = window.buttons["Empty the Trash"]
        XCTAssertTrue(approve.exists)
        XCTAssertFalse(approve.isEnabled)
        XCTAssertTrue(window.buttons["Stop"].exists)
        let confirmation = window.textFields["Confirmation phrase"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 2))
        confirmation.typeText("Trash — 34 items")
        XCTAssertTrue(approve.isEnabled)
        record(name: "approval-red")
    }

    func testPermissionDeniedFixturePresentsOnboardingRecovery() {
        launch(fixture: "permission-denied")
        let window = app.windows["Perry onboarding"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertTrue(window.staticTexts["Meet Perry"].waitForExistence(timeout: 2))
        record(name: "permission-denied")
    }

    func testGuideControlsSurfacePresentsStepControls() {
        app.launchArguments = [
            "-perry.onboarding.completed", "YES",
            "--perry-debug-surface", "guide-controls",
        ]
        app.launch()
        let hud = app.windows["Perry guide controls"]
        XCTAssertTrue(hud.waitForExistence(timeout: 5))
        XCTAssertTrue(hud.staticTexts["Step 2"].exists)
        for button in ["Done", "Skip", "Re-point", "Stop"] {
            XCTAssertTrue(hud.buttons[button].exists, "missing guide control \(button)")
        }
        record(name: "guide-controls")
    }

    func testHistorySurfacePresentsSeededSessions() {
        app.launchArguments = [
            "-perry.onboarding.completed", "YES",
            "--perry-debug-surface", "history",
        ]
        app.launch()
        let window = app.windows["Perry history"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertTrue(window.staticTexts["Move the two named files into Archive"].waitForExistence(timeout: 5))
        XCTAssertTrue(window.staticTexts["Guide me through exporting a PDF"].exists)
        record(name: "history")
    }

    func testPrototypeGalleryPresentsAllThreeArrangements() {
        app.launchArguments = [
            "-perry.onboarding.completed", "YES",
            "--perry-debug-surface", "prototypes",
        ]
        app.launch()
        let window = app.windows["Perry invocation prototypes"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        for title in [
            "A · Segmented Guide/Do + Start",
            "B · Modeless field + Start",
            "C · Field + inline mode toggle",
        ] {
            XCTAssertTrue(window.staticTexts[title].exists, "missing prototype \(title)")
        }
        let startButtons = window.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Start'"))
        XCTAssertGreaterThanOrEqual(startButtons.count, 3)
        record(name: "prototypes")
    }

    private func launch(fixture: String) {
        app.launchArguments = [
            "-perry.onboarding.completed", "YES",
            "--perry-debug-state", fixture,
        ]
        app.launch()
    }

    private func record(name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "fixture-\(name)"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "fixture-\(name)-axtree"
        tree.lifetime = .keepAlways
        add(tree)
    }
}
