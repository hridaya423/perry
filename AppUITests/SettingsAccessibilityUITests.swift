import Foundation
import XCTest

final class SettingsAccessibilityUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-perry.onboarding.completed", "YES",
            "--perry-debug-surface", "settings",
        ]
    }

    override func tearDown() {
        app.terminate()
        app = nil
    }

    func testSettingsCategoriesAndIntegrationControlsAreAccessible() {
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        for category in [
            "General",
            "Voice & Input",
            "Runtimes",
            "Integrations",
            "Memory & Privacy",
            "Appearance",
            "Safety & Advanced",
        ] {
            XCTAssertTrue(element(named: category, in: window).exists, "Missing settings category: \(category)")
        }

        openCategory("Integrations", in: window)
        XCTAssertTrue(window.staticTexts["Slack"].waitForExistence(timeout: 2))
        XCTAssertTrue(window.textFields["OAuth client ID"].exists)
        XCTAssertTrue(window.buttons["Connect"].exists)
        XCTAssertFalse(window.buttons["Connect"].isEnabled)
    }

    func testSettingsRemainReachableWithAccessibilityAppearancePreferences() {
        app.launchArguments += [
            "-AppleInterfaceStyle", "Dark",
            "-AppleIncreaseContrast", "YES",
            "-AppleReduceTransparency", "YES",
            "-AppleReduceMotion", "YES",
        ]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        openCategory("Appearance", in: window)
        XCTAssertTrue(window.staticTexts["Caption opacity"].waitForExistence(timeout: 2))
        XCTAssertTrue(window.staticTexts["Reduced-motion behavior follows the macOS accessibility setting."].exists)
        XCTAssertFalse(window.staticTexts["Accent"].exists)
    }

    func testSettingsRemainReachableAtAccessibilityTextScale() {
        app.launchArguments += ["--perry-debug-text-scale", "accessibility3"]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        openCategory("Memory & Privacy", in: window)
        XCTAssertTrue(window.staticTexts["Memory"].waitForExistence(timeout: 2))
        XCTAssertTrue(window.buttons["Erase all Perry data…"].exists)
    }

    func testBackgroundTasksStorageErrorSuppressesEmptyState() throws {
        let storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Perry-BackgroundTasks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: storageDirectory.path) {
                try FileManager.default.removeItem(at: storageDirectory)
            }
        }

        let taskFile = storageDirectory.appendingPathComponent("tasks.json")
        try Data(#"{"version":9001,"tasks":[]}"#.utf8).write(to: taskFile, options: .atomic)

        app.launchArguments = [
            "-perry.onboarding.completed", "YES",
            "--perry-debug-surface", "background-tasks-storage-error",
            "--perry-debug-storage-directory", storageDirectory.path,
        ]
        defer { app.terminate() }
        app.launch()

        let window = app.windows["Perry background tasks"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        let storageError = window.descendants(matching: .any)
            .matching(identifier: "background-task-storage-error")
            .firstMatch
        XCTAssertTrue(storageError.waitForExistence(timeout: 5))

        let errorMessage = window.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", "Task format version 9001 is unsupported"))
            .firstMatch
        XCTAssertTrue(errorMessage.waitForExistence(timeout: 2))
        XCTAssertTrue(errorMessage.label.contains("Could not read persistence file"))
        XCTAssertTrue(errorMessage.label.contains("Open this data with a compatible Perry version."))
        XCTAssertFalse(window.staticTexts["No queued tasks"].exists)

        let resumeAll = window.buttons["Resume all"]
        XCTAssertTrue(resumeAll.waitForExistence(timeout: 2))
        XCTAssertFalse(resumeAll.isEnabled)
    }

    private func openCategory(_ label: String, in window: XCUIElement) {
        let category = element(named: label, in: window)
        if category.exists {
            category.click()
            return
        }
        element(named: "more toolbar items", in: window).click()
        app.menuItems[label].click()
    }

    private func element(named label: String, in window: XCUIElement) -> XCUIElement {
        window.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label))
            .firstMatch
    }
}

final class OnboardingAccessibilityUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-perry.onboarding.completed", "YES",
            "--perry-debug-surface", "onboarding",
            "-AppleIncreaseContrast", "YES",
            "-AppleReduceTransparency", "YES",
            "-AppleReduceMotion", "YES",
        ]
    }

    override func tearDown() {
        app.terminate()
        app = nil
    }

    func testDeniedPermissionExposesRecoveryControls() {
        app.launch()
        let window = app.windows["Perry onboarding"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertTrue(window.staticTexts["Meet Perry"].waitForExistence(timeout: 2))
        let progress = window.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Onboarding progress"))
            .firstMatch
        XCTAssertEqual(progress.value as? String, "Step 1 of 7")

        window.buttons["Continue"].click()

        XCTAssertTrue(window.staticTexts["Let Perry see your screen"].waitForExistence(timeout: 2))
        XCTAssertTrue(window.buttons["Grant Accessibility"].exists)
        XCTAssertTrue(window.buttons["Grant Screen Recording"].exists)
        XCTAssertTrue(window.buttons["Retry"].exists)
        XCTAssertTrue(window.buttons["Back"].exists)
        XCTAssertFalse(window.buttons["Continue"].isEnabled)
    }

    func testWelcomeAndPermissionRecoveryRemainReachableAtAccessibilityTextScale() {
        app.launchArguments += ["--perry-debug-text-scale", "accessibility3"]
        app.launch()
        let window = app.windows["Perry onboarding"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertTrue(window.staticTexts["Meet Perry"].waitForExistence(timeout: 2))
        XCTAssertTrue(window.buttons["Continue"].exists)

        window.buttons["Continue"].click()

        XCTAssertTrue(window.staticTexts["Let Perry see your screen"].waitForExistence(timeout: 2))
        XCTAssertTrue(window.buttons["Grant Accessibility"].exists)
        XCTAssertTrue(window.buttons["Retry"].exists)
        XCTAssertTrue(window.buttons["Back"].exists)
    }
}

final class SessionPanelAccessibilityUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "--perry-debug-surface", "session",
            "--perry-debug-text-scale", "accessibility3",
            "-AppleIncreaseContrast", "YES",
            "-AppleReduceTransparency", "YES",
            "-AppleReduceMotion", "YES",
        ]
    }

    override func tearDown() {
        app.terminate()
        app = nil
    }

    func testInvocationControlsRemainReachableAtAccessibilityTextScale() {
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        let request = window.textFields["Task request"]
        XCTAssertTrue(request.waitForExistence(timeout: 2))
        XCTAssertTrue(window.buttons["Start dictation"].exists)
        let closeButton = window.buttons["Close session panel"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 2))
        XCTAssertTrue(closeButton.isHittable)

        let modeControl = window.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Guide or Do")).firstMatch
        XCTAssertTrue(modeControl.waitForExistence(timeout: 2))

        let sessionStatus = window.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Session status")).firstMatch
        XCTAssertTrue(sessionStatus.waitForExistence(timeout: 2))
        XCTAssertFalse((sessionStatus.value as? String ?? "").isEmpty)

        let start = window.buttons["Start guiding"]
        XCTAssertTrue(start.waitForExistence(timeout: 2))
        XCTAssertFalse(start.isEnabled)

        let requestFixture = "Rename the selected Finder item"
        app.typeText(requestFixture)
        XCTAssertEqual(request.value as? String, requestFixture)

        XCTAssertTrue(start.isEnabled)
        XCTAssertTrue(start.isHittable)
        XCTAssertTrue(window.frame.contains(start.frame), "Start extends beyond the panel")
    }

    func testNaturalLanguagePreselectsDoVisibly() {
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        let request = window.textFields["Task request"]
        XCTAssertTrue(request.waitForExistence(timeout: 2))

        app.typeText("perry, do clean my desktop")

        XCTAssertTrue(window.checkBoxes["Run in background"].waitForExistence(timeout: 2))
        XCTAssertTrue(window.buttons["Start"].waitForExistence(timeout: 2))
        XCTAssertTrue(window.buttons["Start"].isEnabled)
    }

    func testKeyboardOnlyCompletionSubmitsTheRequest() {
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))

        let request = window.textFields["Task request"]
        XCTAssertTrue(request.waitForExistence(timeout: 2))

        app.typeText("show me how to rename a file")
        app.typeText("\r")

        XCTAssertEqual(request.value as? String, "")
    }
}
