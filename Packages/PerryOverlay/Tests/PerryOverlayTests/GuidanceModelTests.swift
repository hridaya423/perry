import AppKit
import Foundation
import SwiftUI
import Testing
@testable import PerryOverlay

struct PerryGuidanceOverlayTests {
    @Test func rectangleNormalizesClampsAndSerializes() throws {
        let overlay = PerryGuidanceOverlay.rectangle(
            rect: CGRect(x: 120, y: 90, width: -80, height: 60),
            accentHex: "#60A5FA",
            lineWidth: 200,
            fillOpacity: 2,
            caption: "  Target  ",
            duration: 120
        )

        // Platform drift vs upstream: since the macOS 26 SDK, CGRect
        // standardization no longer moves the origin when width/height are
        // negative, so (120, 90, -80x60) normalizes to (120, 90, 80x60),
        // not the (40, 90, ...) older runtimes produced.
        #expect(overlay.rect == PerryGuidanceRect(x: 120, y: 90, width: 80, height: 60))
        #expect(overlay.style.lineWidth == 48)
        #expect(overlay.style.fillOpacity == 0.65)
        #expect(overlay.style.caption == "Target")
        #expect(overlay.duration == 60)
        #expect(overlay.isRenderable)

        let encoded = try JSONEncoder().encode(overlay)
        let decoded = try JSONDecoder().decode(PerryGuidanceOverlay.self, from: encoded)
        #expect(decoded == overlay)

        let clamped = overlay.clamped(to: CGRect(x: 50, y: 100, width: 200, height: 200))
        #expect(clamped.rect == PerryGuidanceRect(x: 120, y: 100, width: 80, height: 50))
    }

    @Test func scribbleRequiresAtLeastTwoPointsAndClampsPoints() throws {
        let overlay = PerryGuidanceOverlay.scribble(
            points: [CGPoint(x: -10, y: 20), CGPoint(x: 100, y: 120), CGPoint(x: 300, y: 10)],
            accentHex: "#F59E0B",
            lineWidth: 0,
            duration: 0.01
        )

        #expect(overlay.isRenderable)
        #expect(overlay.style.lineWidth == 1)
        #expect(overlay.duration == 0.2)

        let clamped = overlay.clamped(to: CGRect(x: 0, y: 0, width: 200, height: 100))
        #expect(clamped.points.map(\.cgPoint) == [
            CGPoint(x: 0, y: 20),
            CGPoint(x: 100, y: 100),
            CGPoint(x: 200, y: 10),
        ])

        let singlePoint = PerryGuidanceOverlay.scribble(points: [CGPoint(x: 1, y: 1)])
        #expect(!singlePoint.isRenderable)
    }

    @Test func hexColorParsingAcceptsDynamicModelOutput() {
        #expect(Color(optionalHex: "#34D399") != nil)
        #expect(Color(optionalHex: "F59E0B") != nil)
        #expect(Color(optionalHex: "#3AF") != nil)
        #expect(Color(optionalHex: "not-a-color") == nil)
        #expect(Color(optionalHex: nil) == nil)
    }
}
