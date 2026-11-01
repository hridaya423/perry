import XCTest
@testable import Perry

final class DictationRoughEdgeTests: XCTestCase {
    func testFinalizationTimeoutDeliversTheLatestPartial() throws {
        let delivered = expectation(description: "Partial delivered")
        var transcripts: [String] = []
        let controller = DictationController(
            onTranscript: {
                transcripts.append($0)
                delivered.fulfill()
            },
            onFailure: { _ in XCTFail("Heard words were dropped") }
        )
        controller.finalizationTimeout = 0.2
        let generation = try controller.beginRecognitionFixture()
        controller.handleRecognition(.transcript("open the", isFinal: false, words: []), generation: generation)
        controller.handleRecognition(.transcript("open the calendar", isFinal: false, words: []), generation: generation)
        controller.finish()

        wait(for: [delivered], timeout: 2)
        XCTAssertEqual(transcripts, ["open the calendar"])
        XCTAssertFalse(controller.isRunning)
    }
}
