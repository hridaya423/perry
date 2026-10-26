import XCTest
import AppKit
import SwiftUI
import PerryCapture
import PerryBrain
@testable import Perry

@MainActor
final class OnboardingDirectorTests: XCTestCase {
    func testRenderWelcomeAppearances() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = AppController(debugStorageDirectory: directory)
        let director = OnboardingDirector()
        director.start()
        defer {
            director.stop()
            controller.notchPresence.stop()
        }
        let destination = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/living-ink-evidence")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for (name, appearance, scheme) in [
            ("light", NSAppearance.Name.aqua, ColorScheme.light),
            ("dark", .darkAqua, .dark)
        ] {
            let frame = NSRect(x: 0, y: 0, width: 720, height: 500)
            let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            let host = NSHostingView(rootView: OnboardingNotchView(director: director, model: controller.homeController.homeModel)
                .environment(\.colorScheme, scheme))
            window.contentView = host
            host.frame = frame
            try await Task.sleep(for: .milliseconds(400))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: destination.appendingPathComponent("welcome-\(name).png"))
            window.close()
        }
    }

    func testLiveFirstAnswerArrivesWithinTheMinute() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PERRY_LIVE_BRAIN"] == "1", "Set TEST_RUNNER_PERRY_LIVE_BRAIN=1 to ask the configured brain for real.")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = AppController(debugStorageDirectory: directory)
        defer { controller.notchPresence.stop() }
        let model = controller.homeController.homeModel
        let director = OnboardingDirector()
        model.onboarding = director
        director.start(resume: false)
        director.skip()
        let started = Date()
        model.onStartConversation?("What can you help me with?")
        var answer: PerryThread.Turn?
        while answer == nil, Date().timeIntervalSince(started) < 60 {
            try await Task.sleep(for: .milliseconds(200))
            if case .thread(let id) = model.sidebarSelection, model.pendingQuestions[id] == nil,
               let turn = model.threads.first(where: { $0.id == id })?.turns.last {
                answer = turn
            }
        }
        let elapsed = Date().timeIntervalSince(started)
        let turn = try XCTUnwrap(answer, "no answer within 60 s; error: \(model.threadErrors.values.first ?? "none")")
        print("onboarding.first_answer.seconds=\(String(format: "%.1f", elapsed)) outcome=\(turn.outcome.map(\.rawValue) ?? "nil") answer=\(turn.answer.prefix(160))")
        XCTAssertFalse(turn.answer.isEmpty)
        XCTAssertLessThan(elapsed, 45, "leaves at least 15 s for reading the greeting and typing")
        director.stop()
    }

    private let granted = PerryPermissionSnapshot(accessibility: true, screenRecording: .granted, microphone: .denied)
    private let denied = PerryPermissionSnapshot(accessibility: false, screenRecording: .denied, microphone: .denied)

    /// The spec order is value before setup: the first conversation precedes
    /// both screen permissions and the model choice.
    func testFirstAnswerPrecedesModelChoice() {
        let director = OnboardingDirector()
        director.start()
        XCTAssertEqual(director.beat, .greet)
        director.skip()
        XCTAssertEqual(director.beat, .firstTalk)
        director.noteBrainChoiceMade()
        XCTAssertEqual(director.beat, .firstTalk, "a brain signal can't skip the first-answer beat")
        director.noteTalkTurnCompleted()
        XCTAssertEqual(director.beat, .firstTalk, "the first answer stays on screen until the user continues")
        XCTAssertTrue(director.firstAnswerReceived)
        director.skip()
        XCTAssertEqual(director.beat, .screenAccess)
        XCTAssertFalse(director.firstAnswerReceived)
        director.stop()
    }

    func testFirstAnswerIsMarkedOnceBetweenStartAndFinish() {
        var marks: [String] = []
        var effects = OnboardingDirector.Effects()
        effects.mark = { marks.append($0.description) }
        let director = OnboardingDirector(effects: effects)
        director.start()
        director.skip()
        director.noteTalkTurnCompleted()
        director.noteTalkTurnCompleted()
        for _ in 0..<5 { director.skip() }
        XCTAssertNil(director.beat)
        XCTAssertEqual(marks, ["onboarding.start", "onboarding.first_answer", "onboarding.finish"])
    }

    func testAGrantMadeDuringTheBeatWaitsForContinue() async {
        var snapshot = denied
        var effects = OnboardingDirector.Effects()
        effects.permissionProbe = { snapshot }
        let director = OnboardingDirector(effects: effects)
        director.start()
        director.skip()
        director.skip()
        await director.refreshPermissions()
        XCTAssertEqual(director.permissions?.requiredPermissionsGranted, false)
        snapshot = granted
        await director.refreshPermissions()
        XCTAssertEqual(director.beat, .screenAccess, "a grant made during the beat stays visible")
        XCTAssertEqual(director.permissions?.requiredPermissionsGranted, true)
        director.skip()
        XCTAssertEqual(director.beat, .brainChoice)
        director.stop()
    }

    func testBackIntoScreenAccessDoesNotAdvanceOnGrantedPermissions() async {
        var effects = OnboardingDirector.Effects()
        effects.permissionProbe = { self.granted }
        let director = OnboardingDirector(effects: effects)
        director.start()
        director.skip()
        director.skip()
        await director.refreshPermissions()
        XCTAssertEqual(director.beat, .brainChoice, "entering forward with access granted skips ahead")
        director.goBack()
        XCTAssertEqual(director.beat, .screenAccess)
        await director.refreshPermissions()
        XCTAssertEqual(director.beat, .screenAccess, "going back must stay on the beat")
        XCTAssertEqual(director.permissions?.requiredPermissionsGranted, true)
        director.stop()
    }

    func testFirstTalkPrefersAnOnDeviceBrain() {
        var preferred = 0
        var effects = OnboardingDirector.Effects()
        effects.preferOnDeviceBrain = { preferred += 1 }
        let director = OnboardingDirector(effects: effects)
        director.start()
        XCTAssertEqual(preferred, 0)
        director.skip()
        XCTAssertEqual(director.beat, .firstTalk)
        XCTAssertEqual(preferred, 1)
        director.stop()
    }

    func testLeavingFirstTalkEndsItsVoiceSessionOnce() {
        for exit in ["back", "skip", "stop", "complete"] {
            var ended = 0
            var effects = OnboardingDirector.Effects()
            effects.endTalk = { ended += 1 }
            let director = OnboardingDirector(effects: effects)
            director.start()
            director.skip()
            director.noteBrainChoiceMade()
            XCTAssertEqual(ended, 0)
            switch exit {
            case "back": director.goBack()
            case "skip": director.skip()
            case "stop": director.stop()
            default:
                director.noteTalkTurnCompleted()
                XCTAssertEqual(ended, 0, "an answer keeps the conversation open")
                director.skip()
            }
            XCTAssertEqual(ended, 1, exit)
            director.stop()
            XCTAssertEqual(ended, 1, exit)
        }
    }

    func testPermissionsDoNotOpenSettingsUntilRequested() async {
        var accessibilityOpened = 0
        var recordingOpened = 0
        var effects = OnboardingDirector.Effects()
        effects.permissionProbe = { self.denied }
        effects.openScreenAccessSettings = { accessibilityOpened += 1 }
        effects.openScreenRecordingSettings = { recordingOpened += 1 }
        let director = OnboardingDirector(effects: effects)
        director.start()
        director.skip()
        director.skip()
        await director.refreshPermissions()
        XCTAssertEqual(director.beat, .screenAccess)
        XCTAssertEqual(accessibilityOpened, 0)
        XCTAssertEqual(recordingOpened, 0)
        director.openAccessibilitySettings()
        XCTAssertEqual(accessibilityOpened, 1)
        director.openScreenRecordingSettings()
        XCTAssertEqual(recordingOpened, 1)
        XCTAssertEqual(director.beat, .screenAccess)
        director.stop()
    }

    func testOnlyStartedPracticeShowsHints() {
        var hints: [String] = []
        var effects = OnboardingDirector.Effects()
        effects.permissionProbe = { self.denied }
        effects.showHint = { if let hint = $0 { hints.append(hint) } }
        let director = OnboardingDirector(effects: effects)
        director.start()
        director.skip()
        director.noteMicrophoneDenied()
        for _ in 0..<4 { director.skip() }
        XCTAssertEqual(director.beat, .finale)
        XCTAssertTrue(hints.isEmpty)
        director.goBack()
        director.startPractice()
        director.notePracticeStepCompleted()
        XCTAssertEqual(hints, [
            OnboardingDirector.practiceHint(for: .pointAsk),
            OnboardingDirector.practiceHint(for: .guide)
        ])
        XCTAssertTrue(OnboardingDirector.practiceHint(for: .pointAsk).contains(TalkGesture.keys))
        director.stop()
    }

    func testGoBackReturnsToPreviousBeatAndUpdatesCheckpoint() throws {
        let name = "perry.onboarding.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var ended = 0
        var effects = OnboardingDirector.Effects()
        effects.permissionProbe = { self.denied }
        effects.endPractice = { ended += 1 }
        let director = OnboardingDirector(effects: effects, defaults: defaults)
        director.goBack()
        XCTAssertNil(director.beat)
        director.start()
        XCTAssertEqual(director.beat, .greet)
        XCTAssertFalse(director.canGoBack)
        director.goBack()
        XCTAssertEqual(director.beat, .greet)
        director.skip()
        director.skip()
        XCTAssertEqual(director.beat, .screenAccess)
        director.goBack()
        XCTAssertEqual(director.beat, .firstTalk)
        XCTAssertEqual(director.direction, .backward)
        XCTAssertEqual(defaults.string(forKey: "perry.onboarding.beat"), "firstTalk")
        for _ in 0..<3 { director.skip() }
        XCTAssertEqual(director.beat, .practice)
        director.startPractice()
        director.goBack()
        XCTAssertEqual(ended, 1)
        XCTAssertEqual(director.beat, .brainChoice)
        XCTAssertEqual(defaults.string(forKey: "perry.onboarding.beat"), "brainChoice")
        XCTAssertFalse(director.practiceStarted)
        director.stop()
        director.goBack()
        XCTAssertNil(director.beat)
    }

    func testScreenPermissionsAdvanceWithoutMicrophonePermission() async {
        var effects = OnboardingDirector.Effects()
        effects.permissionProbe = { self.granted }
        let director = OnboardingDirector(effects: effects)
        director.start()
        director.skip()
        director.skip()
        await director.refreshPermissions()
        XCTAssertEqual(director.beat, .brainChoice)
        director.skip()
        XCTAssertEqual(director.beat, .practice)
        XCTAssertFalse(director.practiceStarted)
        director.stop()
    }

    func testPracticeRequiresAnExplicitStartAndActualCompletionEvents() {
        var starts = 0
        var effects = OnboardingDirector.Effects()
        effects.beginPractice = { starts += 1 }
        let director = OnboardingDirector(effects: effects)
        director.start()
        for _ in 0..<4 { director.skip() }
        XCTAssertEqual(director.beat, .practice)
        XCTAssertEqual(starts, 0)
        director.notePracticeStepCompleted()
        XCTAssertEqual(director.practiceStep, .pointAsk)
        director.startPractice()
        XCTAssertEqual(starts, 1)
        for expected in [OnboardingDirector.PracticeStep.guide, .renameUndo, .dictate] {
            director.notePracticeStepCompleted()
            XCTAssertEqual(director.practiceStep, expected)
        }
        director.notePracticeStepCompleted()
        XCTAssertEqual(director.beat, .finale)
        director.stop()
    }

    func testPracticeWindowCloseAllowsRestart() {
        var starts = 0
        var effects = OnboardingDirector.Effects()
        effects.beginPractice = { starts += 1 }
        let director = OnboardingDirector(effects: effects)
        director.start()
        for _ in 0..<4 { director.skip() }
        director.startPractice()
        XCTAssertTrue(director.practiceStarted)
        director.showPracticeWindow()
        XCTAssertEqual(starts, 2, "Show brings the open practice window forward")
        XCTAssertEqual(director.practiceStep, .pointAsk)
        director.notePracticeWindowClosed()
        XCTAssertFalse(director.practiceStarted)
        director.showPracticeWindow()
        XCTAssertEqual(starts, 2, "a closed window reopens only through Start")
        director.startPractice()
        XCTAssertEqual(starts, 3)
        XCTAssertEqual(director.practiceStep, .pointAsk)
        director.stop()
    }

    func testInterruptedSetupResumesAndCompletionClearsCheckpoint() throws {
        let name = "perry.onboarding.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let first = OnboardingDirector(defaults: defaults)
        first.start()
        first.skip()
        first.noteBrainChoiceMade()
        first.stop()
        let resumed = OnboardingDirector(defaults: defaults)
        resumed.start()
        XCTAssertEqual(resumed.beat, .firstTalk)
        for _ in 0..<4 { resumed.skip() }
        XCTAssertEqual(resumed.beat, .finale)
        resumed.skip()
        XCTAssertNil(resumed.beat)
        let fresh = OnboardingDirector(defaults: defaults)
        fresh.start()
        XCTAssertEqual(fresh.beat, .greet)
        fresh.stop()
    }

    func testEverySetupStageResumesItsSavedBeat() throws {
        for beat in OnboardingDirector.Beat.allCases {
            let name = "perry.onboarding.resume.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            let original = OnboardingDirector(defaults: defaults)
            original.start(resume: false)
            for _ in 0..<OnboardingDirector.Beat.allCases.count where original.beat != beat {
                original.skip()
            }
            XCTAssertEqual(original.beat, beat)
            original.stop()

            let resumed = OnboardingDirector(defaults: defaults)
            resumed.start()
            XCTAssertEqual(resumed.beat, beat)
            XCTAssertFalse(resumed.practiceStarted)
            resumed.stop()
        }
    }

    func testSkippedPermissionPollCannotAdvanceAReplacementBeat() async {
        let entered = expectation(description: "Permission probe entered")
        var release: CheckedContinuation<PerryPermissionSnapshot, Never>?
        var effects = OnboardingDirector.Effects()
        effects.permissionProbe = { await withCheckedContinuation { release = $0; entered.fulfill() } }
        let director = OnboardingDirector(effects: effects)
        director.start()
        director.skip()
        director.skip()
        let poll = Task { await director.refreshPermissions() }
        await fulfillment(of: [entered], timeout: 1)
        director.skip()
        release?.resume(returning: granted)
        await poll.value
        XCTAssertEqual(director.beat, .brainChoice)
        director.stop()
    }
}
