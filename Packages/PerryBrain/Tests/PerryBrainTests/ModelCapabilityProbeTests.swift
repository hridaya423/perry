import XCTest
@testable import PerryBrain

final class ModelCapabilityProbeTests: XCTestCase {
    func testCapabilitiesRequireImageRecognitionAndAToolResultRoundTrip() async throws {
        let provider = ProbeProvider()
        let result = try await ModelCapabilityProbe(provider: provider).run(image: Data([1, 2, 3]), expectedImageText: "582917")
        XCTAssertEqual(result.capabilities, [.streaming, .vision, .tools])
        let requests = await provider.requests
        XCTAssertEqual(requests.count, 4)
        guard case .user(let parts) = requests[1].messages.first else { return XCTFail("Expected the image challenge") }
        let text = parts.compactMap { part -> String? in if case .text(let text) = part { return text }; return nil }.joined()
        XCTAssertFalse(text.contains("582917"))
        guard case .toolResult(let id, _, false) = requests[3].messages.last else {
            return XCTFail("The model must receive its real tool call identity and a synthetic result")
        }
        XCTAssertEqual(id, "probe-call")
    }

    func testTextOnlyModelNeverAdvertisesVisionOrTools() async throws {
        let provider = ProbeProvider(visionAnswer: "I cannot read images", callsTool: false)
        let result = try await ModelCapabilityProbe(provider: provider).run(image: Data([1]), expectedImageText: "582917")
        XCTAssertEqual(result.capabilities, [.streaming])
        guard case .failed = result.vision, case .failed = result.tools else { return XCTFail("Unsupported checks must be visible") }
    }

    func testWrongToolResultDoesNotPassEvenWhenACallWasProduced() async throws {
        let provider = ProbeProvider(echoesToolResult: false)
        let result = try await ModelCapabilityProbe(provider: provider).run(image: Data([1]), expectedImageText: "582917")
        XCTAssertFalse(result.capabilities.contains(.tools))
    }

    func testTimeoutCancelsProviderAndDoesNotRunMoreChecks() async throws {
        let provider = ProbeProvider(stalls: true)
        let result = try await ModelCapabilityProbe(provider: provider, timeout: .milliseconds(30)).run(image: Data([1]), expectedImageText: "582917")
        XCTAssertEqual(result.capabilities, [])
        XCTAssertEqual(result.vision, .notRun)
        XCTAssertEqual(result.tools, .notRun)
        let requests = await provider.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testCancellationCannotPublishPassedCapabilities() async throws {
        let provider = ProbeProvider(stalls: true)
        let task = Task { try await ModelCapabilityProbe(provider: provider).run(image: Data([1]), expectedImageText: "582917") }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation must leave setup unverified")
        } catch is CancellationError {}
    }
}

private actor ProbeProvider: ModelProvider {
    let id: ProviderID = "local.test"
    let displayName = "Test model"
    let capabilities: ModelCapabilities = [.local, .vision, .tools, .streaming]
    private(set) var requests: [ModelRequest] = []
    let visionAnswer: String
    let callsTool: Bool
    let echoesToolResult: Bool
    let stalls: Bool

    init(visionAnswer: String = "582917", callsTool: Bool = true, echoesToolResult: Bool = true, stalls: Bool = false) {
        self.visionAnswer = visionAnswer
        self.callsTool = callsTool
        self.echoesToolResult = echoesToolResult
        self.stalls = stalls
    }

    func warm() async {}

    nonisolated func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for event in try await response(request) { continuation.yield(event) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func response(_ request: ModelRequest) async throws -> [ModelEvent] {
        requests.append(request)
        if stalls { try await Task.sleep(for: .seconds(60)) }
        if case .toolResult(_, let content, _) = request.messages.last,
           case .text(let text) = content.first {
            return [.textDelta(echoesToolResult ? text : "wrong result"), .done(.endTurn)]
        }
        if !request.tools.isEmpty {
            return callsTool
                ? [.toolCall(ToolCall(id: "probe-call", name: "perry_capability_check", arguments: .object(["value": .string("test")]))), .done(.toolUse)]
                : [.textDelta("I would call the tool"), .done(.endTurn)]
        }
        if case .user(let parts) = request.messages.first, parts.contains(where: { if case .image = $0 { return true }; return false }) {
            return [.textDelta(visionAnswer), .done(.endTurn)]
        }
        return [.textDelta("PERRY_READY"), .done(.endTurn)]
    }
}
