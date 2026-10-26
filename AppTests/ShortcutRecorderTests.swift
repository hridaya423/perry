import AppKit
import PerryCore
import SwiftUI
import XCTest
@testable import Perry

@MainActor
final class ShortcutRecorderTests: XCTestCase {
    private func recording(allowsChords: Bool = true) -> ShortcutCapture {
        var capture = ShortcutCapture(saved: .defaultTalk, defaultGesture: .defaultTalk)
        capture.allowsChords = allowsChords
        capture.perryOwners = [.init(gesture: .hold([.function]), name: "Dictate anywhere")]
        capture.systemHotkeys = [SymbolicHotkey(keyCode: 49, modifiers: 0x40000)]
        capture.begin()
        return capture
    }

    func testModifiersHeldAndReleasedBecomeAHoldOfEveryKeyThatWasDown() {
        var capture = recording()
        capture.flagsChanged([.control])
        capture.flagsChanged([.control, .shift])
        capture.flagsChanged([.shift])
        capture.flagsChanged([])
        XCTAssertEqual(capture.state, .captured(.hold([.control, .shift])))
        XCTAssertEqual(capture.saved, .hold([.control, .shift]))
    }

    func testAModifierAndAKeyBecomeAChord() {
        var capture = recording()
        capture.flagsChanged([.option, .command])
        capture.keyDown(2, modifiers: [.option, .command])
        XCTAssertEqual(capture.state, .captured(.chord([.option, .command], keyCode: 2)))
    }

    func testABareKeyIsIgnoredAndHoldsNeedOneToThreeModifiers() {
        var capture = recording()
        capture.keyDown(2, modifiers: [])
        XCTAssertEqual(capture.state, .recording)
        capture.flagsChanged([.control, .option, .command, .shift])
        capture.flagsChanged([])
        XCTAssertEqual(capture.state, .recording)
        capture.flagsChanged([.option, .rightOption])
        capture.flagsChanged([])
        XCTAssertEqual(capture.state, .captured(.hold([.option, .rightOption])))
    }

    func testEscapeCancelsAndDeleteResetsToTheDefault() {
        var capture = recording()
        capture.keyDown(53, modifiers: [])
        XCTAssertEqual(capture.state, .idle)
        XCTAssertEqual(capture.saved, .defaultTalk)
        var reset = ShortcutCapture(saved: .hold([.function]), defaultGesture: .defaultTalk)
        reset.begin()
        reset.keyDown(51, modifiers: [])
        XCTAssertEqual(reset.saved, .defaultTalk)
    }

    func testSpotlightAndFullScreenAreRefusedByName() {
        var capture = recording()
        capture.keyDown(49, modifiers: [.command])
        XCTAssertEqual(capture.state, .rejected(.chord([.command], keyCode: 49), owner: "Spotlight"))
        capture.begin()
        capture.keyDown(3, modifiers: [.command, .control])
        XCTAssertEqual(capture.state, .rejected(.chord([.command, .control], keyCode: 3), owner: "macOS full screen"))
        XCTAssertEqual(capture.saved, .defaultTalk)
    }

    func testConflictsCheckPerryThenMacOSThenKnownAppsAndCanBeOverridden() {
        var capture = recording()
        capture.flagsChanged([.function])
        capture.flagsChanged([])
        XCTAssertEqual(capture.state, .conflict(.hold([.function]), owner: "Dictate anywhere"))
        XCTAssertEqual(capture.saved, .defaultTalk)
        capture.useAnyway()
        XCTAssertEqual(capture.saved, .hold([.function]))

        capture.begin()
        capture.keyDown(49, modifiers: [.control])
        XCTAssertEqual(capture.state, .conflict(.chord([.control], keyCode: 49), owner: "a macOS keyboard shortcut"))
        capture.pickAnother()
        capture.keyDown(49, modifiers: [.option])
        XCTAssertEqual(capture.state, .conflict(.chord([.option], keyCode: 49), owner: "Raycast and Alfred"))
    }

    func testTheTalkRecorderOnlyTakesHolds() {
        var capture = recording(allowsChords: false)
        capture.keyDown(2, modifiers: [.option, .command])
        XCTAssertEqual(capture.state, .recording)
    }

    func testRenderRecorderStates() async throws {
        let destination = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/shortcut-recorder-evidence")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var conflict = recording()
        conflict.flagsChanged([.function])
        conflict.flagsChanged([])
        var captured = recording()
        captured.flagsChanged([.option, .rightOption])
        captured.flagsChanged([])
        var rejected = recording()
        rejected.keyDown(49, modifiers: [.command])
        let states: [(String, ShortcutCapture)] = [
            ("idle", ShortcutCapture(saved: .defaultTalk, defaultGesture: .defaultTalk)),
            ("recording", recording(allowsChords: false)),
            ("captured", captured),
            ("conflict", conflict),
            ("rejected", rejected),
        ]
        for (name, capture) in states {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let frame = NSRect(x: 0, y: 0, width: 520, height: 150)
                let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: appearance)
                let host = NSHostingView(rootView: Form {
                    ShortcutRecorder(title: "Talk", capture: .constant(capture), presets: [.hold([.function]), .hold([.option, .rightOption]), .defaultTalk])
                }.formStyle(.grouped))
                window.contentView = host
                host.frame = frame
                window.orderFrontRegardless()
                try await Task.sleep(for: .milliseconds(250))
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: destination.appendingPathComponent("\(name)-\(appearance == .aqua ? "light" : "dark").png"))
                window.close()
            }
        }
    }
}
