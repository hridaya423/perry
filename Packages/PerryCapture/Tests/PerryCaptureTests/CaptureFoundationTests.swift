import Foundation
import XCTest
@testable import PerryCapture

final class CaptureFoundationTests: XCTestCase {
    func testVisionBoundingBoxMapsToAppKitScreenCoordinates() {
        let capture = makeCapture()
        let observation = PerryTextObservation(
            text: "Save",
            confidence: 0.98,
            normalizedBoundingBox: CGRect(x: 0.1, y: 0.25, width: 0.2, height: 0.1)
        )

        XCTAssertEqual(
            observation.screenRect(in: capture),
            CGRect(x: 200, y: 400, width: 200, height: 80)
        )
    }

    func testScreenRectMapsToTopLeftImagePixels() {
        let capture = makeCapture()

        XCTAssertEqual(
            capture.pixelRect(forScreenRect: CGRect(x: 300, y: 400, width: 500, height: 200)),
            CGRect(x: 400, y: 800, width: 1000, height: 400)
        )
    }

    func testTargetMatcherNormalizesTextAndChoosesHighestConfidence() {
        let observations = [
            PerryTextObservation(
                text: "Save",
                confidence: 0.42,
                normalizedBoundingBox: CGRect(x: 0.1, y: 0.2, width: 0.1, height: 0.1)
            ),
            PerryTextObservation(
                text: "  SÁVE! ",
                confidence: 0.91,
                normalizedBoundingBox: CGRect(x: 0.4, y: 0.5, width: 0.2, height: 0.1)
            ),
        ]

        let match = PerryTextTargetMatcher.firstMatch(
            target: "save",
            in: observations
        )

        XCTAssertEqual(match?.observation.text, "  SÁVE! ")
        XCTAssertEqual(match?.observation.confidence, 0.91)
    }

    func testTargetMatcherContainsModeRespectsWordBoundaries() {
        let observations = [
            PerryTextObservation(
                text: "Save changes",
                confidence: 0.9,
                normalizedBoundingBox: .zero
            ),
            PerryTextObservation(
                text: "Autosave",
                confidence: 0.99,
                normalizedBoundingBox: .zero
            ),
        ]

        let match = PerryTextTargetMatcher.firstMatch(
            target: "save",
            in: observations,
            mode: .contains
        )

        XCTAssertEqual(match?.observation.text, "Save changes")
    }

    func testVisionRecognizerReportsInvalidImageData() {
        let capture = makeCapture()

        XCTAssertThrowsError(try PerryVisionTextRecognizer.recognizeText(in: capture)) { error in
            XCTAssertEqual(error as? PerryCaptureError, .invalidImageData)
        }
    }

    private func makeCapture() -> PerryScreenCapture {
        PerryScreenCapture(
            imageData: Data([0]),
            displayFrame: CGRect(x: 100, y: 200, width: 1000, height: 800),
            screenshotWidthInPixels: 2000,
            screenshotHeightInPixels: 1600
        )
    }
}
