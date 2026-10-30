import AppKit
import XCTest
@testable import Perry

final class ScreenCropTests: XCTestCase {
    private func fixturePNG(width: Int, height: Int) throws -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32
        )!
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: width / 2, height: height / 2).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    func testCropScalesWindowPointsToCapturePixels() throws {
        let png = try fixturePNG(width: 400, height: 200)
        let cropped = try XCTUnwrap(
            ScreenCrop.jpeg(png, rectInWindowPoints: CGRect(x: 0, y: 0, width: 100, height: 50),
                            windowSizePoints: CGSize(width: 200, height: 100))
        )
        let rep = try XCTUnwrap(NSBitmapImageRep(data: cropped))
        XCTAssertEqual(rep.pixelsWide, 200)
        XCTAssertEqual(rep.pixelsHigh, 100)
    }

    func testCropWithoutWindowSizeFallsBackToRawPixels() throws {
        let png = try fixturePNG(width: 400, height: 200)
        let cropped = try XCTUnwrap(
            ScreenCrop.jpeg(png, rectInWindowPoints: CGRect(x: 10, y: 10, width: 50, height: 40),
                            windowSizePoints: .zero)
        )
        let rep = try XCTUnwrap(NSBitmapImageRep(data: cropped))
        XCTAssertEqual(rep.pixelsWide, 50)
        XCTAssertEqual(rep.pixelsHigh, 40)
    }

    func testDegenerateAndOutsideCropsReturnNil() throws {
        let png = try fixturePNG(width: 100, height: 100)
        XCTAssertNil(ScreenCrop.jpeg(png, rectInWindowPoints: CGRect(x: 0, y: 0, width: 0, height: 10),
                                     windowSizePoints: CGSize(width: 100, height: 100)))
        XCTAssertNil(ScreenCrop.jpeg(Data("not an image".utf8), rectInWindowPoints: CGRect(x: 0, y: 0, width: 10, height: 10),
                                     windowSizePoints: CGSize(width: 100, height: 100)))
    }
}
