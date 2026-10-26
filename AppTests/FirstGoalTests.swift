import AppKit
import PerryBrain
import SwiftUI
import XCTest
@testable import Perry

@MainActor
final class FirstGoalTests: XCTestCase {
    private let apps = ["Figma", "Xcode", "Visual Studio Code", "Notes"]

    func testAGoalNamingAnInstalledAppRoutesToGuide() {
        XCTAssertEqual(FirstGoal.route("Figma auto layout", installedApps: apps), .guide(app: "Figma"))
        XCTAssertEqual(FirstGoal.route("debugging in visual studio code", installedApps: apps), .guide(app: "Visual Studio Code"))
        XCTAssertEqual(FirstGoal.route("configurations", installedApps: ["Configurator"]), .ask, "a word inside another word is not an app")
    }

    func testATopicRoutesToAskAndAThingToMakeRoutesToDo() {
        XCTAssertEqual(FirstGoal.route("Spanish", installedApps: apps), .ask)
        XCTAssertEqual(FirstGoal.route("how options work", installedApps: apps), .ask)
        XCTAssertEqual(FirstGoal.route("Write a pitch for my startup", installedApps: apps), .make)
        XCTAssertEqual(FirstGoal.route("make a budget spreadsheet", installedApps: apps), .make)
    }

    func testOnlyScreenTasksNeedScreenRecording() {
        XCTAssertTrue(FirstGoal.guide(app: "Figma").needsScreen)
        XCTAssertTrue(FirstGoal.make.needsScreen)
        XCTAssertFalse(FirstGoal.ask.needsScreen)
        XCTAssertTrue(FirstGoal.askPrompt(for: "Spanish").contains("three-line starter plan"))
    }

    func testStartingTheFirstTaskFinishesWithTheNotchOpen() throws {
        let name = "perry.firstgoal.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var finishes: [Bool] = []
        var effects = OnboardingDirector.Effects()
        effects.finish = { finishes.append($0) }
        let director = OnboardingDirector(effects: effects, defaults: defaults)
        director.start()
        director.beginFirstTask()
        XCTAssertEqual(director.beat, .hello, "only the last beat starts a task")
        while director.beat != .firstGoal { director.skip() }
        director.beginFirstTask()
        XCTAssertNil(director.beat)
        XCTAssertEqual(finishes, [true])
        XCTAssertNil(defaults.string(forKey: "perry.onboarding.beat"))
    }

    func testARelaunchResumesAtFirstGoalWithTheGoalIntact() throws {
        let name = "perry.firstgoal.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try MemoryFiles(directory: directory).setProfileField("Learning goal", "Figma auto layout")
        let before = OnboardingDirector(defaults: defaults)
        before.start()
        while before.beat != .firstGoal { before.skip() }
        before.stop()
        let after = OnboardingDirector(defaults: defaults)
        after.start()
        XCTAssertEqual(after.beat, .firstGoal)
        XCTAssertEqual(FirstGoal.savedGoal(in: MemoryFiles(directory: directory)), "Figma auto layout")
    }

    func testRenderTheGoalStates() async throws {
        let destination = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/onboarding-evidence")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let director = OnboardingDirector()
        director.start(resume: false)
        while director.beat != .firstGoal { director.skip() }
        defer { director.stop() }
        for (name, goal) in [("guide", "Figma auto layout"), ("ask", "Spanish")] {
            let frame = NSRect(x: 0, y: 0, width: PerryTheme.Sizing.onboardingContentWidth, height: 380)
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            let host = NSHostingView(rootView: FirstGoalBeat(director: director, model: HomeModel(), goal: goal, installedApps: apps)
                .padding(.horizontal, 24)
                .padding(.bottom, 14)
                .frame(width: frame.width, height: frame.height)
                .background(PerryTheme.Colors.canvas)
                .foregroundStyle(PerryTheme.Colors.text)
                .environment(\.colorScheme, .dark))
            window.contentView = host
            host.frame = frame
            window.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(500))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: destination.appendingPathComponent("firstgoal-\(name).png"))
            window.close()
        }
    }
}
