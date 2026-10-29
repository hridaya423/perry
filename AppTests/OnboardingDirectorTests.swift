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

    private let granted = PerryPermissionSnapshot(accessibility: true, screenRecording: .granted, microphone: .granted)
    private let denied = PerryPermissionSnapshot(accessibility: false, screenRecording: .denied, microphone: .denied)

    private func suite() throws -> UserDefaults {
        let name = "perry.onboarding.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testBeatsRunHelloToFirstGoal() {
        XCTAssertEqual(OnboardingDirector.Beat.allCases, [.hello, .brain, .access, .interview, .firstGoal])
        let director = OnboardingDirector()
        director.start()
        var seen: [OnboardingDirector.Beat] = []
        while let beat = director.beat {
            seen.append(beat)
            director.skip()
        }
        XCTAssertEqual(seen, OnboardingDirector.Beat.allCases)
    }

    func testOldSavedBeatNamesRestartAtHello() throws {
        for old in ["greet", "firstTalk", "screenAccess", "brainChoice", "practice", "finale", "shortcuts", "apps", "nonsense"] {
            let defaults = try suite()
            defaults.set(old, forKey: "perry.onboarding.beat")
            let director = OnboardingDirector(defaults: defaults)
            director.start()
            XCTAssertEqual(director.beat, .hello, old)
            XCTAssertEqual(defaults.string(forKey: "perry.onboarding.beat"), "hello")
            director.stop()
        }
    }

    func testBackWorksFromEveryBeatButHello() throws {
        let defaults = try suite()
        let director = OnboardingDirector(defaults: defaults)
        director.goBack()
        XCTAssertNil(director.beat)
        director.start()
        XCTAssertFalse(director.canGoBack)
        director.goBack()
        XCTAssertEqual(director.beat, .hello)
        let beats = OnboardingDirector.Beat.allCases
        for index in beats.indices.dropFirst() {
            director.skip()
            XCTAssertEqual(director.beat, beats[index])
            XCTAssertTrue(director.canGoBack)
            director.goBack()
            XCTAssertEqual(director.beat, beats[index - 1])
            XCTAssertEqual(director.direction, .backward)
            XCTAssertEqual(defaults.string(forKey: "perry.onboarding.beat"), beats[index - 1].rawValue)
            director.skip()
            XCTAssertEqual(director.direction, .forward)
        }
        director.stop()
    }

    func testCloseKeepsTheBeatAndParksSetupInThePeek() throws {
        let defaults = try suite()
        var dismissed = 0
        var effects = OnboardingDirector.Effects()
        effects.dismiss = { dismissed += 1 }
        let director = OnboardingDirector(effects: effects, defaults: defaults)
        director.start()
        director.skip()
        director.skip()
        director.close()
        XCTAssertNil(director.beat)
        XCTAssertEqual(dismissed, 1)
        XCTAssertEqual(defaults.string(forKey: "perry.onboarding.beat"), "access")
        XCTAssertTrue(defaults.bool(forKey: "perry.onboarding.dismissed"))
        XCTAssertFalse(OnboardingCoordinator.opensAtLaunch(completed: false, dismissed: true))
        XCTAssertTrue(OnboardingCoordinator.opensAtLaunch(completed: false, dismissed: false))
        XCTAssertFalse(OnboardingCoordinator.opensAtLaunch(completed: true, dismissed: false))

        let setup = PeekRow.setup
        XCTAssertEqual(setup.title, "Finish setup")
        XCTAssertEqual(PeekRow.rows(needsYou: nil, setup: setup, tasks: [], perrys: [], suggestions: []).map(\.id), [setup.id])
        let task = PeekRow(id: "t", kind: .task(working: true), title: "Task", status: "")
        XCTAssertEqual(PeekRow.rows(needsYou: nil, setup: setup, tasks: [task, task], perrys: [], suggestions: []).first?.id, setup.id)
        XCTAssertNil(PeekRow.rows(needsYou: nil, setup: nil, tasks: [], perrys: [], suggestions: []).first)

        let resumed = OnboardingDirector(defaults: defaults)
        resumed.start()
        XCTAssertEqual(resumed.beat, .access)
        XCTAssertFalse(defaults.bool(forKey: "perry.onboarding.dismissed"), "resuming clears the parked state")
        resumed.stop()
    }

    func testBackClosesTheBrainChooserBeforeLeavingTheBeat() {
        let director = OnboardingDirector()
        director.start(resume: false)
        director.skip()
        director.choosingBrain = true
        director.goBack()
        XCTAssertEqual(director.beat, .brain)
        XCTAssertFalse(director.choosingBrain)
        director.goBack()
        XCTAssertEqual(director.beat, .hello)
        director.stop()
    }

    func testHelloSavesTheNameAndMovesOn() {
        var saved: [String] = []
        var effects = OnboardingDirector.Effects()
        effects.saveName = { saved.append($0) }
        let director = OnboardingDirector(effects: effects)
        director.start()
        director.acceptName("  Ada \n")
        XCTAssertEqual(saved, ["Ada"])
        XCTAssertEqual(director.beat, .brain)
        director.acceptName("Grace")
        XCTAssertEqual(saved, ["Ada"], "only Hello takes a name")
        director.goBack()
        director.acceptName("   ")
        XCTAssertEqual(saved, ["Ada"], "a blank name keeps the saved one")
        XCTAssertEqual(director.beat, .brain)
        director.stop()

        XCTAssertEqual(OnboardingDirector.suggestedName(saved: nil, fullName: "Ada Lovelace"), "Ada")
        XCTAssertEqual(OnboardingDirector.suggestedName(saved: "Countess", fullName: "Ada Lovelace"), "Countess")
        XCTAssertEqual(OnboardingDirector.suggestedName(saved: nil, fullName: ""), "")
    }

    func testEveryBeatIsMarkedAndTheRunIsBracketed() {
        var marks: [String] = []
        var effects = OnboardingDirector.Effects()
        effects.mark = { marks.append($0.description) }
        let director = OnboardingDirector(effects: effects)
        director.start()
        while director.beat != nil { director.skip() }
        XCTAssertEqual(marks, ["onboarding.start"] + OnboardingDirector.Beat.allCases.map { "onboarding.beat.\($0.rawValue)" } + ["onboarding.finish"])
    }

    func testFirstAnswerIsMarkedOnce() {
        var marks: [String] = []
        var effects = OnboardingDirector.Effects()
        effects.mark = { marks.append($0.description) }
        let director = OnboardingDirector(effects: effects)
        director.start()
        director.noteTalkTurnCompleted()
        director.skip()
        director.noteTalkTurnCompleted()
        XCTAssertEqual(marks.filter { $0 == "onboarding.first_answer" }.count, 1)
        director.stop()
        director.noteTalkTurnCompleted()
        XCTAssertEqual(marks.filter { $0 == "onboarding.first_answer" }.count, 1)
    }

    func testAccessAdvancesOnlyWhenEnteredForwardWithEveryGrant() async {
        var snapshot = granted
        var effects = OnboardingDirector.Effects()
        effects.permissionProbe = { snapshot }
        effects.systemProbe = { .answered }
        let director = OnboardingDirector(effects: effects)
        director.start()
        director.skip()
        director.skip()
        await director.refreshPermissions()
        XCTAssertEqual(director.beat, .interview, "entering forward with access granted skips ahead")
        director.goBack()
        await director.refreshPermissions()
        XCTAssertEqual(director.beat, .access, "going back never bounces forward")
        director.skip()
        director.goBack()
        snapshot = denied
        await director.refreshPermissions()
        snapshot = granted
        await director.refreshPermissions()
        XCTAssertEqual(director.beat, .access, "a grant made during the beat waits for Continue")
        XCTAssertEqual(director.accessGranted, true)
        director.stop()
    }

    func testAccessNeverAsksForScreenRecording() async {
        var asked: [PrivacyPane] = []
        var effects = OnboardingDirector.Effects()
        effects.permissionProbe = { self.denied }
        effects.systemProbe = { .answered }
        effects.grant = { asked.append($0) }
        let director = OnboardingDirector(effects: effects)
        director.start()
        await director.grant(.accessibility)
        XCTAssertEqual(asked, [], "only the access beat asks")
        director.skip()
        director.skip()
        await director.grant(.accessibility)
        await director.grant(.microphone)
        XCTAssertEqual(asked, [.accessibility, .microphone])
        XCTAssertFalse(OnboardingDirector.accessPanes.contains(.screenRecording))
        director.stop()
    }

    func testSkippedPermissionProbeCannotAdvanceAReplacementBeat() async {
        let entered = expectation(description: "Permission probe entered")
        var release: CheckedContinuation<PerryPermissionSnapshot, Never>?
        var effects = OnboardingDirector.Effects()
        effects.permissionProbe = { await withCheckedContinuation { release = $0; entered.fulfill() } }
        effects.systemProbe = { .answered }
        let director = OnboardingDirector(effects: effects)
        director.start()
        director.skip()
        director.skip()
        let probe = Task { await director.refreshPermissions() }
        await fulfillment(of: [entered], timeout: 1)
        director.skip()
        release?.resume(returning: granted)
        await probe.value
        XCTAssertEqual(director.beat, .interview)
        director.stop()
    }

    func testEveryBeatResumesAndFinishingClearsTheCheckpoint() throws {
        for beat in OnboardingDirector.Beat.allCases {
            let defaults = try suite()
            let original = OnboardingDirector(defaults: defaults)
            original.start(resume: false)
            while original.beat != beat { original.skip() }
            original.stop()
            let resumed = OnboardingDirector(defaults: defaults)
            resumed.start()
            XCTAssertEqual(resumed.beat, beat)
            while resumed.beat != nil { resumed.skip() }
            XCTAssertNil(defaults.string(forKey: "perry.onboarding.beat"))
            let fresh = OnboardingDirector(defaults: defaults)
            fresh.start()
            XCTAssertEqual(fresh.beat, .hello)
            fresh.stop()
        }
    }
}
