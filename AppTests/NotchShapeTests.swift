import AppKit
import SwiftUI
import XCTest
@testable import Perry

final class NotchShapeTests: XCTestCase {
    func testPathIsClosedAndStaysInsideItsRect() {
        let rect = CGRect(x: 0, y: 0, width: 476, height: 256)
        for shape in [NotchShape.closed, NotchShape.open] {
            let path = shape.path(in: rect)
            XCTAssertTrue(rect.insetBy(dx: -0.5, dy: -0.5).contains(path.boundingRect), "\(shape)")
            var closes = false
            path.forEach { if case .closeSubpath = $0 { closes = true } }
            XCTAssertTrue(closes, "\(shape)")
            XCTAssertTrue(path.contains(CGPoint(x: rect.midX, y: rect.midY)))
            XCTAssertFalse(path.contains(CGPoint(x: 1, y: rect.maxY - 1)), "bottom corner is rounded away")
        }
    }

    func testRadiiAnimateTogether() {
        var shape = NotchShape.closed
        shape.animatableData = NotchShape.open.animatableData
        XCTAssertEqual(shape.topRadius, 18)
        XCTAssertEqual(shape.bottomRadius, 22)
    }

    @MainActor
    func testRenderClosedAndOpen() throws {
        let destination = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/notch-rebuild-evidence")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for (name, shape, size) in [("closed", NotchShape.closed, CGSize(width: 240, height: 38)),
                                    ("open", NotchShape.open, CGSize(width: 476, height: 256))] {
            let renderer = ImageRenderer(content: shape.surface.frame(width: size.width, height: size.height)
                .padding(24).background(Color(white: 0.85)))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            try XCTUnwrap(image.representation(using: .png, properties: [:]))
                .write(to: destination.appendingPathComponent("notch-shape-\(name).png"))
        }
    }
}
