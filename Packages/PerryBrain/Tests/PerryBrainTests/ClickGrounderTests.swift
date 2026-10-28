import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PerryBrain
import PerryCore

private final class Replies: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [String]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [String]) { queue = replies }

    func next(_ request: URLRequest) -> Data {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        let content = queue.removeFirst()
        let body: JSONValue = .object(["choices": .array([.object(["message": .object(["content": .string(content)])])])])
        return try! body.data()
    }
}

final class ClickGrounderTests: XCTestCase {
    private func png(width: Int, height: Int) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    private func grounder(_ replies: Replies) -> ClickGrounder {
        ClickGrounder(
            endpoint: { .init(baseURL: URL(string: "http://127.0.0.1:9999/v1")!, apiKey: "secret") },
            send: { replies.next($0) }
        )
    }

    private func sentImageSize(_ request: URLRequest) throws -> CGSize {
        let body = try JSONValue(parsing: request.httpBody!)
        let url = body["messages"]?.arrayValue?[1]["content"]?.arrayValue?[1]["image_url"]?["url"]?.stringValue ?? ""
        let data = Data(base64Encoded: String(url.split(separator: ",")[1]))!
        let image = ClickGrounder.decode(data)!
        return CGSize(width: image.width, height: image.height)
    }

    func testAgreeingSamplesClickTheFirstPointWithoutZooming() async throws {
        let replies = Replies(Array(repeating: #"{"action": "click", "x": 250, "y": 500}"#, count: 3))
        let located = try await grounder(replies).locate("the Save button", screenshot: png(width: 2880, height: 1800), windowSize: CGSize(width: 1440, height: 900))
        XCTAssertEqual(located, .init(point: CGPoint(x: 360, y: 450), confident: true))
        XCTAssertEqual(replies.requests.count, 3)
        let first = replies.requests[0]
        XCTAssertEqual(first.url?.absoluteString, "http://127.0.0.1:9999/v1/chat/completions")
        XCTAssertEqual(first.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        let body = try JSONValue(parsing: first.httpBody!)
        XCTAssertEqual(body["temperature"]?.doubleValue, 0)
        XCTAssertEqual(body["response_format"]?["json_schema"]?["name"]?.stringValue, "click")
        XCTAssertEqual(body["messages"]?.arrayValue?[1]["content"]?.arrayValue?[0]["text"]?.stringValue, "Goal: the Save button")
        let size = try sentImageSize(first)
        XCTAssertLessThanOrEqual(Int(size.width * size.height), ClickGrounder.firstPassPixels + 2000)
        XCTAssertEqual(size.width / size.height, 1.6, accuracy: 0.01)
    }

    func testAcceptedFirstPointSkipsTheCheckPasses() async throws {
        let replies = Replies([#"{"action": "click", "x": 250, "y": 500}"#])
        let located = try await grounder(replies).locate(
            "the Save button", screenshot: png(width: 2880, height: 1800), windowSize: CGSize(width: 1440, height: 900),
            accepts: { $0 == CGPoint(x: 360, y: 450) }
        )
        XCTAssertEqual(located, .init(point: CGPoint(x: 360, y: 450), confident: true))
        XCTAssertEqual(replies.requests.count, 1)
    }

    func testScatteredSamplesZoomIntoTheRegionAndMapBack() async throws {
        let replies = Replies([
            #"{"action":"click","x":100,"y":100}"#,
            #"{"action":"click","x":200,"y":120}"#,
            #"{"action":"click","x":120,"y":110}"#,
            #"{"action":"click","x":500,"y":500}"#,
        ])
        let located = try await grounder(replies).locate("a gear icon", screenshot: png(width: 2000, height: 1000), windowSize: CGSize(width: 1000, height: 500))
        XCTAssertEqual(replies.requests.count, 4)
        XCTAssertFalse(located.confident)
        XCTAssertEqual(located.point.x, 250, accuracy: 0.5)
        XCTAssertEqual(located.point.y, 125, accuracy: 0.5)
        XCTAssertEqual(try sentImageSize(replies.requests[3]), CGSize(width: 1000, height: 500))
    }

    func testTheZoomCentresOnTheFirstAnswerNotOnStraySamples() async throws {
        let replies = Replies([
            #"{"action":"click","x":900,"y":900}"#,
            #"{"action":"click","x":100,"y":100}"#,
            #"{"action":"click","x":120,"y":100}"#,
            #"{"action":"click","x":500,"y":500}"#,
        ])
        let located = try await grounder(replies).locate("Search this folder", screenshot: png(width: 2000, height: 1000), windowSize: CGSize(width: 1000, height: 500))
        XCTAssertEqual(located.point.x, 750, accuracy: 0.5)
        XCTAssertEqual(located.point.y, 375, accuracy: 0.5)
        let images = try replies.requests.prefix(3).map { try JSONValue(parsing: $0.httpBody!)["messages"]?.arrayValue?[1]["content"]?.arrayValue?[1]["image_url"]?["url"]?.stringValue }
        XCTAssertEqual(Set(images).count, 1)
    }

    func testAMalformedReplyIsRetriedOnceThenReported() async throws {
        let replies = Replies(["I think the button is on the left", "still no"])
        do {
            _ = try await grounder(replies).locate("x", screenshot: png(width: 100, height: 100), windowSize: CGSize(width: 100, height: 100))
            XCTFail("Expected a failure")
        } catch ClickGrounder.GroundingError.noPoint(let reply) {
            XCTAssertEqual(reply, "still no")
        }
        XCTAssertEqual(replies.requests.count, 2)
    }

    func testParsingToleratesSpacingAndClampsToTheImage() {
        XCTAssertEqual(ClickGrounder.parsePoint(#"{"action": "click", "x":687, "y": 78 }"#), CGPoint(x: 0.687, y: 0.078))
        XCTAssertEqual(ClickGrounder.parsePoint(#"{"action":"click","x":-116,"y":1200}"#), CGPoint(x: 0, y: 1))
        XCTAssertNil(ClickGrounder.parsePoint(#"{"point_2d": [10, 20]}"#))
    }

    func testZoomRegionShiftsInwardAtTheEdges() {
        let size = CGSize(width: 2000, height: 1000)
        XCTAssertEqual(ClickGrounder.zoomRegion(around: CGPoint(x: 0.98, y: 0.02), imageSize: size), CGRect(x: 1000, y: 0, width: 1000, height: 500))
        XCTAssertEqual(ClickGrounder.zoomRegion(around: CGPoint(x: 0.5, y: 0.5), imageSize: size), CGRect(x: 500, y: 250, width: 1000, height: 500))
    }

    func testSnapPicksTheSmallestClickableElementUnderThePoint() {
        let window = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let elements = [
            ObservedElement(id: "toolbar", role: "AXGroup", label: "", frame: CGRect(x: 0, y: 0, width: 1000, height: 60), windowID: 1),
            ObservedElement(id: "row", role: "AXRow", label: "Downloads", frame: CGRect(x: 0, y: 0, width: 300, height: 40), windowID: 1),
            ObservedElement(id: "gear", role: "AXButton", label: "Action", frame: CGRect(x: 10, y: 10, width: 24, height: 24), windowID: 1),
            ObservedElement(id: "pane", role: "AXButton", label: "", frame: CGRect(x: 0, y: 0, width: 900, height: 700), windowID: 1),
        ]
        XCTAssertEqual(ClickGrounder.snapTarget(CGPoint(x: 20, y: 20), elements: elements, window: window)?.id, "gear")
        XCTAssertEqual(ClickGrounder.snapTarget(CGPoint(x: 200, y: 20), elements: elements, window: window)?.id, "row")
        XCTAssertNil(ClickGrounder.snapTarget(CGPoint(x: 500, y: 300), elements: elements, window: window))
    }
}
