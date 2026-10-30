import AppKit
import XCTest
import PerryBrain
import PerryCore
import PerryGuide
import PerryOverlay
@testable import Perry

final class InkAccentSamplerTests: XCTestCase {
    private func makeJPEG(gray: UInt8, size: Int = 64) throws -> Data {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for i in 0..<(size * size) {
            pixels[i * 4] = gray
            pixels[i * 4 + 1] = gray
            pixels[i * 4 + 2] = gray
            pixels[i * 4 + 3] = 255
        }
        let image = pixels.withUnsafeMutableBytes { raw -> CGImage? in
            guard let context = CGContext(
                data: raw.baseAddress, width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: size * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return context.makeImage()
        }
        let cgImage = try XCTUnwrap(image)
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, cgImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testMintOnDarkTealOnLight() throws {
        let bounds = CGRect(x: 500, y: 300, width: 100, height: 100)
        let center = CGPoint(x: 550, y: 350)
        XCTAssertEqual(
            InkAccentSampler.accentHex(
                imageJPEG: try makeJPEG(gray: 20),
                elementCenterAX: center, windowBoundsAX: bounds
            ),
            InkColor.onDarkHex
        )
        XCTAssertEqual(
            InkAccentSampler.accentHex(
                imageJPEG: try makeJPEG(gray: 235),
                elementCenterAX: center, windowBoundsAX: bounds
            ),
            InkColor.onLightHex
        )
    }

    func testNilOnBadInputs() throws {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertNil(InkAccentSampler.accentHex(
            imageJPEG: Data(), elementCenterAX: .zero, windowBoundsAX: bounds))
        XCTAssertNil(InkAccentSampler.accentHex(
            imageJPEG: try makeJPEG(gray: 128),
            elementCenterAX: .zero, windowBoundsAX: .zero))
    }
}
