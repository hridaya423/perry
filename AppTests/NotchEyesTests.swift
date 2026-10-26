import AppKit
import PerryOverlay
import SwiftUI
import XCTest
@testable import Perry

final class NotchEyesTests: XCTestCase {
    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    func testScheduleStaysInRangeAndNeverRunsWhilePaused() throws {
        var rng = Seeded(state: 7)
        var scheduler = EyeScheduler()
        var doubles = 0
        for _ in 0..<2000 {
            let blink = try XCTUnwrap(scheduler.nextBlink(mood: .resting, using: &rng))
            XCTAssertTrue(EyeScheduler.blinkRange.contains(blink.delay))
            if blink.double { doubles += 1 }
            XCTAssertTrue(EyeScheduler.glanceRange.contains(try XCTUnwrap(scheduler.nextGlance(mood: .resting, using: &rng))))
            XCTAssertTrue(EyeScheduler.workingGlanceRange.contains(try XCTUnwrap(scheduler.nextGlance(mood: .working, using: &rng))))
        }
        XCTAssertEqual(Double(doubles) / 2000, EyeScheduler.doubleBlinkChance, accuracy: 0.03)
        for mood in [NotchEyeMood.needsYou, .asleep] {
            XCTAssertNil(scheduler.nextBlink(mood: mood, using: &rng))
            XCTAssertNil(scheduler.nextGlance(mood: mood, using: &rng))
        }
        scheduler.paused = true
        for mood in NotchEyeMood.allCases {
            XCTAssertNil(scheduler.nextBlink(mood: mood, using: &rng))
            XCTAssertNil(scheduler.nextGlance(mood: mood, using: &rng))
        }
    }

    func testMoodsMapFromVoiceAndTaskState() {
        XCTAssertEqual(NotchEyeMood(PerryMood(voice: .listening, buddy: .idle)), .listening)
        XCTAssertEqual(NotchEyeMood(PerryMood(voice: .idle, buddy: .acting)), .working)
        XCTAssertEqual(NotchEyeMood(PerryMood(voice: .processing, buddy: .idle)), .working)
        XCTAssertEqual(NotchEyeMood(PerryMood(voice: .idle, buddy: .awaitingApproval)), .needsYou)
        XCTAssertEqual(NotchEyeMood(PerryMood(voice: .idle, buddy: .idle)), .resting)
    }

    @MainActor
    func testRenderEachState() throws {
        let destination = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/notch-rebuild-evidence")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let states: [(String, NotchEyeMood, Bool)] = [("resting", .resting, false), ("hover", .resting, true),
                                                      ("listening", .listening, false), ("working", .working, false),
                                                      ("needs-you", .needsYou, false), ("asleep", .asleep, false)]
        for (name, mood, hover) in states {
            for notch in [CGSize(width: 185, height: 32), nil] {
                let model = NotchEyesModel()
                model.setMood(mood)
                if hover { model.hover(true) }
                let view = NotchEyesView(model: model, notch: notch, height: notch?.height ?? 24)
                    .frame(width: 340, height: 48)
                    .background(Color(red: 0.80, green: 0.83, blue: 0.88))
                    .environment(\.colorScheme, .dark)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 3
                let image = try XCTUnwrap(renderer.nsImage?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
                try XCTUnwrap(image.representation(using: .png, properties: [:]))
                    .write(to: destination.appendingPathComponent("eyes-\(notch == nil ? "pill" : "notch")-\(name).png"))
            }
        }
    }
}
