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

    @Test func translatedShiftsRectAndPoints() {
        let delta = CGPoint(x: 10, y: -20)

        let rect = PerryGuidanceOverlay.rectangle(
            rect: CGRect(x: 100, y: 200, width: 40, height: 30)
        ).translated(by: delta)
        #expect(rect.rect == PerryGuidanceRect(x: 110, y: 180, width: 40, height: 30))

        let scribble = PerryGuidanceOverlay.scribble(
            points: [CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4)]
        ).translated(by: delta)
        #expect(scribble.points.map(\.cgPoint) == [
            CGPoint(x: 11, y: -18),
            CGPoint(x: 13, y: -16),
        ])
    }

    @Test func hexColorParsingAcceptsDynamicModelOutput() {
        #expect(Color(optionalHex: "#34D399") != nil)
        #expect(Color(optionalHex: "F59E0B") != nil)
        #expect(Color(optionalHex: "#3AF") != nil)
        #expect(Color(optionalHex: "not-a-color") == nil)
        #expect(Color(optionalHex: nil) == nil)
    }

    @Test func semanticThemeColorsResolveInLightAndDarkAppearances() {
        let colors = [
            PerryOverlayTheme.Colors.accent,
            PerryOverlayTheme.Colors.ink,
            PerryOverlayTheme.Colors.selection,
            PerryOverlayTheme.Colors.labelForeground,
            PerryOverlayTheme.Colors.labelBackground,
            PerryOverlayTheme.Colors.eyeHighlight,
            PerryOverlayTheme.Colors.captionSurface,
            PerryOverlayTheme.Colors.captionText,
            PerryOverlayTheme.Colors.shadow,
        ]
        let appearances = [NSAppearance(named: .aqua), NSAppearance(named: .darkAqua)].compactMap { $0 }

        for appearance in appearances {
            for color in colors {
                let resolved = resolved(color, in: appearance)
                #expect(resolved.alphaComponent > 0)
            }
        }
    }

    private func resolved(_ color: Color, in appearance: NSAppearance) -> NSColor {
        var resolved = NSColor.clear
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.deviceRGB)!
        }
        return resolved
    }
}

struct MarkGeometryTests {
    private let element = CGRect(x: 400, y: 300, width: 90, height: 30)

    /// `point` used to be `.scribble([center, center])` — a zero-length path
    /// that renders nothing. The mark is now a real dot with a leader.
    @Test func pointMarkProducesANonDegenerateDotAndLeader() {
        let overlay = PerryGuidanceOverlay.pointMark(center: CGPoint(x: 445, y: 315))
        let cg = overlay.points.map(\.cgPoint)

        #expect(overlay.kind == PerryGuidanceOverlayKind.scribble)
        #expect(overlay.isRenderable)
        #expect(Set(cg).count > 2)
        // The loop of the dot stays within ~6pt of the element center.
        let dot = cg.dropFirst(2)
        for p in dot {
            #expect(hypot(p.x - 445, p.y - 315) < 7)
        }
        // The leader approaches from below-left (AppKit: -x, -y).
        #expect(cg[0].x < 445 && cg[0].y < 315)
    }

    /// The arrow keeps its below-approach and carries a real head: two barbs
    /// retraced at the tip, all short of the element's bottom edge.
    @Test func arrowMarkEndsInAHeadShortOfTheElement() {
        let overlay = PerryGuidanceOverlay.arrowMark(to: element)
        let cg = overlay.points.map(\.cgPoint)

        #expect(cg.count == 5)
        #expect(cg[1] == cg[3]) // tip retraced between barbs
        for p in cg {
            #expect(p.y < element.minY) // never overlaps the element
        }
        #expect(cg[1].y > cg[2].y && cg[1].y > cg[4].y) // head points up at the element
    }

    /// `underline` drew at `maxY + 4` — above the element in AppKit space.
    /// It belongs below: `minY -`.
    @Test func underlineMarkSitsBelowTheElement() {
        let overlay = PerryGuidanceOverlay.underlineMark(below: element)
        for p in overlay.points.map(\.cgPoint) {
            #expect(p.y < element.minY)
            #expect(p.x >= element.minX && p.x <= element.maxX)
        }
    }

    /// `ring` is an ellipse padded off the element, not the old crisp rect.
    @Test func ringMarkIsAPaddedEllipse() {
        let overlay = PerryGuidanceOverlay.ringMark(around: element, padding: 8)
        #expect(overlay.kind == PerryGuidanceOverlayKind.ellipse)
        #expect(overlay.isRenderable)
        let r = overlay.rect!.cgRect
        #expect(r.minX == element.minX - 8 && r.minY == element.minY - 8)
        #expect(r.width == element.width + 16 && r.height == element.height + 16)
    }

    @Test func ellipseInkIsAClosedDeterministicLoopInsideTheRect() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 50)
        let a = InkStroke.ellipse(in: rect)
        let b = InkStroke.ellipse(in: rect)
        #expect(a == b)
        #expect(a.count > 14)
        // Every sample stays inside (plus jitter slack); loop closes near start.
        for p in a {
            #expect(rect.insetBy(dx: -2, dy: -2).contains(p))
        }
        #expect(hypot(a.last!.x - a.first!.x, a.last!.y - a.first!.y) < 3)
    }
}
