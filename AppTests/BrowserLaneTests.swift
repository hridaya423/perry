import Foundation
import Network
import PerryBrain
import XCTest
@testable import Perry

final class BrowserLaneTests: XCTestCase {
    func testActivePortFileGivesPortAndPath() {
        XCTAssertEqual(ChromeEndpoint.activePort("9222\n/devtools/browser/abc\n")?.port, 9222)
        XCTAssertEqual(ChromeEndpoint.activePort("9222\n/devtools/browser/abc\n")?.path, "/devtools/browser/abc")
        XCTAssertNil(ChromeEndpoint.activePort(""))
        XCTAssertNil(ChromeEndpoint.activePort("nope\n/x"))
    }

    func testRemoteDebuggingToggleIsReadFromLocalState() {
        XCTAssertEqual(ChromeEndpoint.remoteDebuggingSetting(localState: Data(#"{"devtools":{"remote_debugging":{"user-enabled":false}}}"#.utf8)), false)
        XCTAssertEqual(ChromeEndpoint.remoteDebuggingSetting(localState: Data(#"{"devtools":{"remote_debugging":{"user-enabled":true}}}"#.utf8)), true)
        XCTAssertNil(ChromeEndpoint.remoteDebuggingSetting(localState: Data("{}".utf8)))
    }

    func testDiscoveryExplainsHowToTurnOnRemoteDebugging() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("perry-browser-\(UUID().uuidString)")
        let profile = home.appendingPathComponent("Library/Application Support/Google/Chrome")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(#"{"devtools":{"remote_debugging":{"user-enabled":false}}}"#.utf8).write(to: profile.appendingPathComponent("Local State"))
        do {
            _ = try await ChromeEndpoint.discover(environment: [:], home: home)
            XCTFail("no browser is listening")
        } catch let error as BrowserError {
            XCTAssertEqual(error, .remoteDebuggingOff)
            XCTAssertTrue(error.localizedDescription.contains("browser.connect"))
        }
        let direct = try await ChromeEndpoint.discover(environment: [ChromeEndpoint.overrideKey: "ws://127.0.0.1:1/devtools/browser/x"], home: home)
        XCTAssertEqual(direct.absoluteString, "ws://127.0.0.1:1/devtools/browser/x")
    }

    func testConnectOnlyTouchesTheBrowserNamedOrInFront() {
        let running = [
            ChromeEndpoint.RunningApp(bundleID: "com.google.Chrome", name: "Google Chrome"),
            ChromeEndpoint.RunningApp(bundleID: "com.google.chrome.for.testing", name: "Google Chrome for Testing"),
            ChromeEndpoint.RunningApp(bundleID: "com.apple.finder", name: "Finder"),
        ]
        let behindChrome = ["dev.perry.Perry", "com.google.chrome.for.testing", "com.google.Chrome"]
        XCTAssertEqual(ChromeEndpoint.browser(named: "Google Chrome for Testing", running: running, windowOrder: ["com.google.Chrome"])?.bundleID, "com.google.chrome.for.testing")
        XCTAssertEqual(ChromeEndpoint.browser(named: nil, running: running, windowOrder: behindChrome)?.bundleID, "com.google.chrome.for.testing")
        XCTAssertNil(ChromeEndpoint.browser(named: "Brave Browser", running: running, windowOrder: behindChrome), "a named browser that isn't open is never swapped for another")
        XCTAssertNil(ChromeEndpoint.browser(named: "Finder", running: running, windowOrder: behindChrome))
        XCTAssertNil(ChromeEndpoint.browser(named: nil, running: running, windowOrder: ["dev.perry.Perry"]), "with no browser window on screen, nothing is picked")
    }

    func testKeysCarryTheCodesARealKeyboardSends() {
        let shifted = BrowserKeys.stroke("!")
        XCTAssertEqual(shifted.code, "Digit1")
        XCTAssertEqual(shifted.virtualKey, 49)
        XCTAssertEqual(shifted.modifiers, 8)
        let enter = BrowserKeys.events(for: BrowserKeys.stroke("Enter"))
        XCTAssertEqual(enter.map { $0["type"]?.stringValue }, ["keyDown", "keyUp"])
        XCTAssertEqual(enter.first?["text"]?.stringValue, "\r")
        let letter = BrowserKeys.events(for: BrowserKeys.stroke("a"))
        XCTAssertEqual(letter.map { $0["type"]?.stringValue }, ["keyDown", "char", "keyUp"])
        let selectAll = BrowserKeys.events(for: BrowserKeys.stroke("a", modifiers: BrowserKeys.modifiers(["cmd"])))
        XCTAssertEqual(selectAll.map { $0["type"]?.stringValue }, ["rawKeyDown", "keyUp"])
        XCTAssertEqual(selectAll.first?["commands"], .array([.string("SelectAll")]))
        XCTAssertNil(selectAll.first?["text"], "a shortcut must not type its letter")
        XCTAssertEqual(BrowserKeys.stroke("é").code, "")
        XCTAssertEqual(BrowserKeys.events(for: BrowserKeys.stroke("é"))[1]["text"]?.stringValue, "é")
    }

    func testCommandsGoToTheTabInFrontAndRepliesMatchTheirRequests() async throws {
        let chrome = try FakeChrome(pages: [("T1", "Docs", "https://example.com/docs"), ("T2", "Mail", "https://example.com/mail")])
        defer { chrome.stop() }
        let lane = BrowserLane(devTools: ChromeDevTools(discover: { chrome.url }))
        let run = UUID()
        let value = try await BrowserTools.evaluate("document.title", lane: lane, run: run)
        XCTAssertEqual(value.stringValue, "evaluated document.title in S-T1")
        let tab = try await lane.attach(run: run, to: "T2")
        XCTAssertEqual(tab.title, "Mail")
        let second = try await BrowserTools.evaluate("1+1", lane: lane, run: run)
        XCTAssertEqual(second.stringValue, "evaluated 1+1 in S-T2")
        XCTAssertTrue(chrome.methods.contains("Target.detachFromTarget"), "the previous tab is released")
    }

    func testIllegalReturnIsRetriedInsideAFunction() async throws {
        let chrome = try FakeChrome(pages: [("T1", "Docs", "https://example.com")])
        defer { chrome.stop() }
        let lane = BrowserLane(devTools: ChromeDevTools(discover: { chrome.url }))
        let value = try await BrowserTools.evaluate("return 5", lane: lane, run: UUID())
        XCTAssertEqual(value.stringValue, "evaluated (async function(){return 5\n})() in S-T1")
    }

    func testSensitivePagesAreRefusedLikeSensitiveWindows() async throws {
        let chrome = try FakeChrome(pages: [("T1", "Acme Checkout", "https://shop.example/checkout")])
        defer { chrome.stop() }
        let lane = BrowserLane(devTools: ChromeDevTools(discover: { chrome.url }))
        do {
            _ = try await BrowserTools.evaluate("document.title", lane: lane, run: UUID())
            XCTFail("a checkout page is protected")
        } catch let error as BrowserError {
            XCTAssertEqual(error, .protectedPage)
        }
        XCTAssertFalse(chrome.methods.contains("Runtime.evaluate"))
    }

    func testAPageThatBecomesSensitiveIsRefusedOnTheNextCall() async throws {
        let chrome = try FakeChrome(pages: [("T1", "Cart", "https://shop.example/cart")])
        defer { chrome.stop() }
        let lane = BrowserLane(devTools: ChromeDevTools(discover: { chrome.url }))
        let run = UUID()
        _ = try await BrowserTools.evaluate("1", lane: lane, run: run)
        chrome.retitle("T1", "Payment details")
        do {
            _ = try await BrowserTools.evaluate("2", lane: lane, run: run)
            XCTFail("the page turned into a payment page")
        } catch let error as BrowserError {
            XCTAssertEqual(error, .protectedPage)
        }
    }

    func testAnOpenDialogIsReportedAndChromeErrorsSurface() async throws {
        let chrome = try FakeChrome(pages: [("T1", "Docs", "https://example.com")])
        defer { chrome.stop() }
        let devTools = ChromeDevTools(discover: { chrome.url })
        let lane = BrowserLane(devTools: devTools)
        let run = UUID()
        let session = try await lane.session(run: run)
        chrome.push(method: "Page.javascriptDialogOpening", params: ["type": .string("confirm"), "message": .string("Leave?")], session: session)
        try await pollUntilAsync { try await lane.dialog(run: run) != nil }
        let dialog = try await lane.dialog(run: run)
        XCTAssertEqual(dialog?["message"]?.stringValue, "Leave?")
        do {
            _ = try await lane.command("Broken.method", run: run)
            XCTFail("Chrome refused")
        } catch let error as BrowserError {
            XCTAssertEqual(error, .chrome("'Broken.method' wasn't found"))
        }
    }

    func testAnUnansweredCommandTimesOutAndALostConnectionFailsWaitingCalls() async throws {
        let chrome = try FakeChrome(pages: [("T1", "Docs", "https://example.com")])
        defer { chrome.stop() }
        let devTools = ChromeDevTools(discover: { chrome.url })
        do {
            _ = try await devTools.send("Never.answer", timeout: .milliseconds(200))
            XCTFail("no reply")
        } catch let error as BrowserError {
            XCTAssertEqual(error, .timedOut("Never.answer"))
        }
        async let waiting = devTools.send("Never.answer", timeout: .seconds(10))
        try await Task.sleep(for: .milliseconds(100))
        chrome.dropConnections()
        do {
            _ = try await waiting
            XCTFail("the connection closed")
        } catch let error as BrowserError {
            XCTAssertEqual(error, .connectionLost)
        }
        let reconnected = try await devTools.send("Target.getTargets")
        XCTAssertEqual(reconnected["targetInfos"]?.arrayValue?.count, 1)
    }

    private func pollUntilAsync(_ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition never held")
    }
}

private final class FakeChrome: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-chrome")
    private var connections: [NWConnection] = []
    private var pages: [(id: String, title: String, url: String)]
    private var received: [String] = []
    var methods: [String] { queue.sync { received } }
    let url: URL

    init(pages: [(String, String, String)]) throws {
        self.pages = pages.map { (id: $0.0, title: $0.1, url: $0.2) }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        listener = try NWListener(using: parameters, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        var accept: ((NWConnection) -> Void)?
        listener.newConnectionHandler = { accept?($0) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        url = URL(string: "ws://127.0.0.1:\(listener.port!.rawValue)/devtools/browser/fake")!
        accept = { [weak self] connection in self?.accept(connection) }
    }

    func stop() {
        listener.cancel()
        dropConnections()
    }

    func dropConnections() {
        queue.sync {
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    func retitle(_ id: String, _ title: String) {
        queue.sync {
            if let index = pages.firstIndex(where: { $0.id == id }) { pages[index].title = title }
        }
    }

    func push(method: String, params: [String: JSONValue], session: String) {
        queue.sync {
            let message: JSONValue = .object(["method": .string(method), "params": .object(params), "sessionId": .string(session)])
            connections.forEach { send(message, on: $0) }
        }
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil, let data, let request = try? JSONValue(parsing: data) else { return }
            self.reply(to: request, on: connection)
            self.receive(on: connection)
        }
    }

    private func reply(to request: JSONValue, on connection: NWConnection) {
        let method = request["method"]?.stringValue ?? ""
        received.append(method)
        let params = request["params"]
        let session = request["sessionId"]?.stringValue
        let id = request["id"] ?? .null
        let result: JSONValue
        switch method {
        case "Never.answer":
            return
        case "Broken.method":
            send(.object(["id": id, "error": .object(["code": .number(-32601), "message": .string("'Broken.method' wasn't found")])]), on: connection)
            return
        case "Browser.getVersion":
            result = .object(["product": .string("Fake/1")])
        case "Target.getTargets":
            result = .object(["targetInfos": .array(pages.map { .object(["targetId": .string($0.id), "type": .string("page"), "title": .string($0.title), "url": .string($0.url)]) })])
        case "Target.getTargetInfo":
            let page = pages.first { $0.id == params?["targetId"]?.stringValue }
            result = .object(["targetInfo": .object(["targetId": .string(page?.id ?? ""), "title": .string(page?.title ?? ""), "url": .string(page?.url ?? "")])])
        case "Target.attachToTarget":
            result = .object(["sessionId": .string("S-" + (params?["targetId"]?.stringValue ?? ""))])
        case "Runtime.evaluate":
            let expression = params?["expression"]?.stringValue ?? ""
            if expression.hasPrefix("return") {
                result = .object(["result": .object(["type": .string("object"), "subtype": .string("error")]),
                                  "exceptionDetails": .object(["text": .string("Uncaught"), "exception": .object(["description": .string("SyntaxError: Illegal return statement")])])])
            } else {
                result = .object(["result": .object(["type": .string("string"), "value": .string("evaluated \(expression) in \(session ?? "browser")")])])
            }
        default:
            result = .object([:])
        }
        send(.object(["id": id, "result": result]), on: connection)
    }

    private func send(_ message: JSONValue, on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
        connection.send(content: try? JSONEncoder().encode(message), contentContext: context, isComplete: true, completion: .idempotent)
    }
}
