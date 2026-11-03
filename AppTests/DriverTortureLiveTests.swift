import AppKit
import CryptoKit
import XCTest
import PerryCore
import PerryGuide
import PerryRuntimes
@testable import Perry

private protocol TortureDriver: Actor {
    func capture(target hint: ScreenTargetHint?, sessionID: String) async throws -> ScreenCapturedWindow
    func execute(_ action: ComputerAction, sessionID: String) async throws -> StepResult
    func insertText(_ text: String, target hint: ScreenTargetHint, sessionID: String) async throws -> ScreenWindowTarget
    func shutdown() async
}

extension CuaDriverClient: TortureDriver {}
extension AgentDesktopClient: TortureDriver {}

private struct TortureFailure: Error, CustomStringConvertible {
    let description: String
}

private struct TortureEnvironment {
    let driver: String
    let agentDesktop: URL?
    let fixture: URL
    let output: URL
    let repeats: Int

    static func load() throws -> TortureEnvironment {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PERRY_TORTURE"] == "1" else {
            throw XCTSkip("Set PERRY_TORTURE=1, PERRY_TORTURE_DRIVER=cua|hybrid and build scripts/lab/torture-fixture")
        }
        return TortureEnvironment(
            driver: environment["PERRY_TORTURE_DRIVER"] ?? "hybrid",
            agentDesktop: environment["PERRY_TORTURE_AGENT_DESKTOP"].map { URL(fileURLWithPath: $0) },
            fixture: URL(fileURLWithPath: environment["PERRY_TORTURE_FIXTURE"] ?? "/tmp/PerryTortureFixture.app"),
            output: URL(fileURLWithPath: environment["PERRY_TORTURE_OUT"] ?? "/tmp/perry-torture.jsonl"),
            repeats: Int(environment["PERRY_TORTURE_REPEATS"] ?? "") ?? 5
        )
    }

    var label: String {
        guard driver == "hybrid" else { return "cua" }
        let version = agentDesktop.flatMap { url -> String? in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = url
            process.arguments = ["version"]
            process.standardOutput = pipe
            try? process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            return (json?["data"] as? [String: Any])?["version"] as? String
        } ?? "bundled"
        return "hybrid-\(version)"
    }
}

private final class Fixture {
    let app: NSRunningApplication
    let logURL: URL
    let hint: ScreenTargetHint

    init(app: NSRunningApplication, logURL: URL, hint: ScreenTargetHint) {
        self.app = app
        self.logURL = logURL
        self.hint = hint
    }

    static func launch(_ url: URL, title: String = "Perry Torture Fixture") async throws -> Fixture {
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("perry-torture-\(UUID().uuidString).log")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        configuration.arguments = [logURL.path, title]
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let ready = Self.read(logURL).first(where: { $0.hasPrefix("ready ") })?.split(separator: " "), ready.count == 3 {
                try await Task.sleep(for: .milliseconds(700))
                return Fixture(app: app, logURL: logURL, hint: ScreenTargetHint(
                    bundleID: "dev.perry.torture-fixture",
                    processID: pid_t(ready[1])!,
                    windowID: Int64(ready[2])!
                ))
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        app.forceTerminate()
        throw TortureFailure(description: "fixture never became ready")
    }

    static func read(_ url: URL) -> [String] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    var lines: [String] { Self.read(logURL).filter { !$0.hasPrefix("ready ") } }

    func lines(_ prefix: String) -> [String] { lines.filter { $0.hasPrefix(prefix + " ") || $0 == prefix } }

    func last(_ prefix: String) -> String? {
        lines(prefix).last.map { String($0.dropFirst(prefix.count + 1)) }
    }

    func decodedLast(_ prefix: String) -> String? {
        last(prefix).flatMap { Data(base64Encoded: $0) }.flatMap { String(data: $0, encoding: .utf8) }
    }

    func wait(for prefix: String, timeout: TimeInterval = 4) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !lines(prefix).isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    func settle(_ seconds: Double = 0.8) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    func quit() {
        app.forceTerminate()
        try? FileManager.default.removeItem(at: logURL)
    }
}

private struct Outcome {
    var pass: Bool
    var detail: String
}

private final class TortureRun {
    let driver: any TortureDriver
    let fixture: Fixture
    let session = "torture-\(UUID().uuidString.prefix(8))"
    var capture: ScreenCapturedWindow?
    var actionMilliseconds: [Double] = []
    var captureMilliseconds: [Double] = []

    init(driver: any TortureDriver, fixture: Fixture) {
        self.driver = driver
        self.fixture = fixture
    }

    @discardableResult
    func read() async throws -> ScreenCapturedWindow {
        let started = Date()
        let window = try await driver.capture(target: fixture.hint, sessionID: session)
        captureMilliseconds.append(Date().timeIntervalSince(started) * 1000)
        capture = window
        return window
    }

    var elements: [AXElement] { capture?.accessibilitySnapshotModel?.elements ?? [] }

    func element(_ label: String, role: AXElement.Role? = nil, index: Int = 0) throws -> AXElement {
        if role == nil, index == 0, !elements.contains(where: { $0.label == label }),
           let ref = capture?.elementDetails.first(where: { $0.value.value == label })?.key,
           let element = elements.first(where: { $0.stableID == ref }) {
            return element
        }
        let matches = elements
            .filter { ($0.label == label || $0.value == label) && (role == nil || $0.role == role) }
            .sorted { $0.frame.y == $1.frame.y ? $0.frame.x < $1.frame.x : $0.frame.y < $1.frame.y }
        guard matches.indices.contains(index) else {
            let seen = elements.map { "\($0.role.rawValue):\($0.label ?? $0.value ?? "-")" }.joined(separator: ", ")
            throw TortureFailure(description: "no \(label) #\(index) in snapshot: \(seen)")
        }
        return matches[index]
    }

    func target(_ element: AXElement) -> ComputerTarget {
        .element(id: element.stableID, label: nil, point: nil)
    }

    func act(_ operation: ComputerAction.Operation) async throws {
        let started = Date()
        defer { actionMilliseconds.append(Date().timeIntervalSince(started) * 1000) }
        _ = try await driver.execute(ComputerAction(stepID: "torture", operation: operation), sessionID: session)
    }

    func click(_ label: String, role: AXElement.Role? = nil, index: Int = 0) async throws {
        try await act(.click(target(try element(label, role: role, index: index))))
    }

    func type(_ text: String, into label: String) async throws {
        try await act(.typeText(text: text, target: target(try element(label))))
    }

    func scale() throws -> Double {
        guard let capture, let source = CGImageSourceCreateWithData(capture.screenshotData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw TortureFailure(description: "capture had no screenshot")
        }
        return Double(image.width) / 900
    }

    func titleBar() throws -> Double {
        guard let capture, let source = CGImageSourceCreateWithData(capture.screenshotData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw TortureFailure(description: "capture had no screenshot")
        }
        return Double(image.height) / (try scale()) - 720
    }

    func pixels(_ x: Double, _ y: Double) throws -> ComputerCoordinates {
        let scale = try scale()
        return ComputerCoordinates(x: x * scale, y: (y + (try titleBar())) * scale)
    }
}

final class DriverTortureLiveTests: XCTestCase {
    private var environment: TortureEnvironment!
    private var driverLabel = ""

    override func setUp() async throws {
        environment = try TortureEnvironment.load()
        driverLabel = environment.label
    }

    private func makeDriver(foreground: Bool = false) throws -> any TortureDriver {
        let cuaConfiguration = try XCTUnwrap(CuaDriverConfiguration.discoverWithInstalledApps(), "the bundled cua-driver is missing")
        let cua = CuaDriverClient(configuration: cuaConfiguration, allowsRestart: true, allowsForegroundInput: foreground && environment.driver != "hybrid")
        guard environment.driver == "hybrid" else { return cua }
        let bundled = try XCTUnwrap(AgentDesktopConfiguration.discover(), "the bundled agent-desktop is missing")
        let configuration = AgentDesktopConfiguration(
            executableURL: environment.agentDesktop ?? bundled.executableURL,
            hostBundleID: bundled.hostBundleID,
            stateDirectoryURL: FileManager.default.temporaryDirectory.appendingPathComponent("perry-torture-ad-\(UUID().uuidString)")
        )
        return AgentDesktopClient(configuration: configuration, allowsRestart: true, allowsForegroundInput: foreground, fallback: cua)
    }

    private static func observeUser() -> String {
        let cursor = CGEvent(source: nil)?.location ?? .zero
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
        return "\(Int(cursor.x)),\(Int(cursor.y)) \(front)"
    }

    private func record(_ scenario: String, rep: Int, outcome: Outcome, run: TortureRun?, error: Error?, userDisturbed: Bool, total: Double) {
        let row: [String: Any] = [
            "driver": driverLabel,
            "scenario": scenario,
            "rep": rep,
            "pass": outcome.pass,
            "detail": outcome.detail,
            "error": error.map { String(describing: $0) } ?? NSNull(),
            "user_disturbed": userDisturbed,
            "action_ms": run?.actionMilliseconds ?? [],
            "capture_ms": run?.captureMilliseconds ?? [],
            "total_ms": total,
            "log": run?.fixture.lines ?? [],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: row), let line = String(data: data, encoding: .utf8) else { return }
        let url = environment.output
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data((line + "\n").utf8))
            try? handle.close()
        } else {
            try? Data((line + "\n").utf8).write(to: url)
        }
    }

    private func scenario(
        _ name: String,
        repeats: Int? = nil,
        foreground: Bool = false,
        _ body: (TortureRun) async throws -> Outcome
    ) async throws {
        var failures: [String] = []
        for rep in 0..<(repeats ?? environment.repeats) {
            let fixture = try await Fixture.launch(environment.fixture)
            let driver = try makeDriver(foreground: foreground)
            let run = TortureRun(driver: driver, fixture: fixture)
            let before = Self.observeUser()
            let started = Date()
            var outcome = Outcome(pass: false, detail: "")
            var thrown: Error?
            do {
                outcome = try await body(run)
            } catch {
                thrown = error
                outcome = Outcome(pass: false, detail: "threw")
            }
            let total = Date().timeIntervalSince(started) * 1000
            let disturbed = !foreground && Self.observeUser() != before
            if disturbed {
                outcome.pass = false
                outcome.detail += " user disturbed: \(before) -> \(Self.observeUser())"
            }
            record(name, rep: rep, outcome: outcome, run: run, error: thrown, userDisturbed: disturbed, total: total)
            if !outcome.pass {
                failures.append("rep \(rep): \(outcome.detail) \(thrown.map { String(describing: $0) } ?? "") log=\(fixture.lines)")
            }
            await driver.shutdown()
            fixture.quit()
        }
        XCTAssertTrue(failures.isEmpty, "\(driverLabel) \(name):\n" + failures.joined(separator: "\n"))
    }

    private func realApp(_ name: String, _ body: (any TortureDriver, String) async throws -> Outcome) async throws {
        var failures: [String] = []
        for rep in 0..<max(1, environment.repeats) {
            let driver = try makeDriver()
            let session = "torture-real-\(UUID().uuidString.prefix(8))"
            let before = Self.observeUser()
            let started = Date()
            var outcome = Outcome(pass: false, detail: "")
            var thrown: Error?
            do {
                outcome = try await body(driver, session)
            } catch {
                thrown = error
                outcome = Outcome(pass: false, detail: "threw")
            }
            let disturbed = Self.observeUser() != before
            if disturbed { outcome.pass = false }
            record(name, rep: rep, outcome: outcome, run: nil, error: thrown, userDisturbed: disturbed, total: Date().timeIntervalSince(started) * 1000)
            if !outcome.pass { failures.append("rep \(rep): \(outcome.detail) \(thrown.map { String(describing: $0) } ?? "")") }
            await driver.shutdown()
        }
        XCTAssertTrue(failures.isEmpty, "\(driverLabel) \(name):\n" + failures.joined(separator: "\n"))
    }

    private static func element(in window: ScreenCapturedWindow, matching labels: [String]) -> AXElement? {
        let elements = window.accessibilitySnapshotModel?.elements ?? []
        for wanted in labels {
            if let match = elements.first(where: { $0.role == .button && ($0.label ?? "").caseInsensitiveCompare(wanted) == .orderedSame }) {
                return match
            }
        }
        return nil
    }

    func testCalculatorComputesWithoutDoubledPresses() async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        let calculatorURL = try XCTUnwrap(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.calculator"))
        let calculator = try await NSWorkspace.shared.openApplication(at: calculatorURL, configuration: configuration)
        try await Task.sleep(for: .seconds(1.5))
        defer { calculator.terminate() }
        try await realApp("calculator") { driver, session in
            let hint = ScreenTargetHint(bundleID: "com.apple.calculator")
            var window = try await driver.capture(target: hint, sessionID: session)
            let keys: [[String]] = [["All Clear", "Clear", "AC"], ["1"], ["2"], ["Multiply", "×", "multiply"], ["3"], ["4"], ["Equals", "=", "equals"]]
            var timings: [Int] = []
            for labels in keys {
                guard let button = Self.element(in: window, matching: labels) else {
                    if labels.first == "All Clear" { continue }
                    let seen = (window.accessibilitySnapshotModel?.elements ?? []).compactMap(\.label).joined(separator: ",")
                    return Outcome(pass: false, detail: "no \(labels) in \(seen)")
                }
                let started = Date()
                _ = try await driver.execute(ComputerAction(stepID: "calc", operation: .click(.element(id: button.stableID, label: nil, point: nil))), sessionID: session)
                timings.append(Int(Date().timeIntervalSince(started) * 1000))
                try await Task.sleep(for: .milliseconds(250))
                window = try await driver.capture(target: hint, sessionID: session)
            }
            let shown = window.accessibilitySnapshot ?? ""
            let lines = shown.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            let numbers = { (line: String) in line.split { !$0.isNumber }.map(String.init) }
            let display = lines.filter { numbers($0).contains("408") || $0.contains("×") }
            let pass = lines.contains { numbers($0).contains("408") } && !lines.contains { numbers($0).contains("1122") }
            return Outcome(pass: pass, detail: "display=\(display.prefix(4)) click_ms=\(timings)")
        }
    }

    func testTextEditDocumentGetsTheExactTextAndSaves() async throws {
        let text = "Perry wrote this: ünïcødé ✓ 👋\nSecond line\twith a tab"
        try await realApp("textedit") { driver, session in
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("perry-torture-\(UUID().uuidString.prefix(8)).txt")
            try Data().write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            let textEdit = try XCTUnwrap(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit"))
            _ = try await NSWorkspace.shared.open([file], withApplicationAt: textEdit, configuration: configuration)
            try await Task.sleep(for: .seconds(2))
            let hint = ScreenTargetHint(bundleID: "com.apple.TextEdit", windowTitle: file.lastPathComponent)
            _ = try await driver.capture(target: hint, sessionID: session)
            let started = Date()
            _ = try await driver.execute(ComputerAction(stepID: "type", operation: .typeText(text: text, target: nil)), sessionID: session)
            let typed = Int(Date().timeIntervalSince(started) * 1000)
            _ = try await driver.execute(ComputerAction(stepID: "save", operation: .hotkey(keys: ["cmd", "s"], target: nil)), sessionID: session)
            var saved = ""
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(200))
                saved = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                if !saved.isEmpty { break }
            }
            _ = try? await driver.execute(ComputerAction(stepID: "close", operation: .hotkey(keys: ["cmd", "w"], target: nil)), sessionID: session)
            return Outcome(pass: saved == text, detail: "type_ms=\(typed) saved=\(saved.debugDescription.prefix(90))")
        }
    }

    func testPressableButtonLandsOnce() async throws {
        try await scenario("press-works") { run in
            try await run.read()
            try await run.click("Works", role: .button)
            await run.fixture.settle()
            let lines = run.fixture.lines("works")
            return Outcome(pass: lines.count == 1, detail: "\(lines)")
        }
    }

    func testButtonThatIgnoresTheAccessibilityPressLandsOnce() async throws {
        try await scenario("lying-button") { run in
            try await run.read()
            try await run.click("Inert", role: .button)
            await run.fixture.settle(1.2)
            let lines = run.fixture.lines("inert")
            return Outcome(pass: lines.count == 1, detail: "\(lines)")
        }
    }

    func testConsequentialButtonThatIgnoresThePressIsNeverDoubled() async throws {
        try await scenario("lying-send") { run in
            try await run.read()
            try await run.click("Send", role: .button)
            await run.fixture.settle(1.2)
            let lines = run.fixture.lines("send")
            return Outcome(pass: lines.count <= 1, detail: lines.isEmpty ? "not landed" : "\(lines)")
        }
    }

    func testUnlabelledIconButtonIsNeverDoubled() async throws {
        try await scenario("lying-icon") { run in
            try await run.read()
            let icon = try XCTUnwrap(run.elements.first { $0.role == .button && ($0.label ?? "").isEmpty && $0.frame.width < 60 }, "no icon button")
            try await run.act(.click(run.target(icon)))
            await run.fixture.settle(1.2)
            let lines = run.fixture.lines("icon")
            return Outcome(pass: lines.count <= 1, detail: lines.isEmpty ? "not landed" : "\(lines)")
        }
    }

    func testIdenticalTwinButtonsHitTheChosenRow() async throws {
        try await scenario("twin-delete") { run in
            try await run.read()
            try await run.click("Delete", role: .button, index: 2)
            await run.fixture.settle()
            let lines = run.fixture.lines("delete")
            return Outcome(pass: lines.count == 1 && lines[0].hasPrefix("delete 3 "), detail: "\(lines)")
        }
    }

    func testRefFromBeforeTheListChangedNeverHitsAnotherRow() async throws {
        try await scenario("stale-twin") { run in
            try await run.read()
            let third = try run.element("Delete", role: .button, index: 2)
            try await run.click("Delete", role: .button, index: 0)
            await run.fixture.settle()
            var refused = false
            do {
                try await run.act(.click(run.target(third)))
            } catch {
                refused = true
            }
            await run.fixture.settle()
            let lines = run.fixture.lines("delete").map { $0.split(separator: " ").prefix(2).joined(separator: " ") }
            let pass = lines == ["delete 1", "delete 3"] || (refused && lines == ["delete 1"])
            return Outcome(pass: pass, detail: "\(lines) refused=\(refused)")
        }
    }

    func testUnicodeTextLandsExactly() async throws {
        let text = "Héllo wörld — 日本語 👩‍👩‍👧 e\u{301} ñ"
        try await scenario("type-unicode") { run in
            try await run.read()
            try await run.type(text, into: "Name")
            await run.fixture.settle()
            let value = run.fixture.decodedLast("name")
            return Outcome(pass: value == text, detail: "got \(value.map { String($0.prefix(80)) } ?? "nil")")
        }
    }

    func testLongTextLandsExactly() async throws {
        let text = (0..<40).map { "Line \($0): the quick brown fox jumps over the lazy dog, ünïcödé ✓." }.joined(separator: " ")
        try await scenario("type-long") { run in
            try await run.read()
            try await run.type(text, into: "Name")
            await run.fixture.settle(1.5)
            let value = run.fixture.decodedLast("name") ?? ""
            return Outcome(pass: value == text, detail: "len \(value.count)/\(text.count)")
        }
    }

    func testTextThatLooksLikeFlagsIsTypedLiterally() async throws {
        let text = "--session evil -- --headed -i"
        try await scenario("type-flags") { run in
            try await run.read()
            try await run.type(text, into: "Name")
            await run.fixture.settle()
            let value = run.fixture.decodedLast("name")
            return Outcome(pass: value == text, detail: "got \(value ?? "nil")")
        }
    }

    func testPasswordLandsWithoutTheCommandLine() async throws {
        let secret = "hunter2-Ünï-\(UUID().uuidString.prefix(6))"
        try await scenario("type-password") { run in
            try await run.read()
            let field = try run.element("Password")
            let watcher = Task.detached { () -> Bool in
                let deadline = Date().addingTimeInterval(6)
                while Date() < deadline, !Task.isCancelled {
                    let listing = Process()
                    let pipe = Pipe()
                    listing.executableURL = URL(fileURLWithPath: "/bin/ps")
                    listing.arguments = ["-axww", "-o", "command="]
                    listing.standardOutput = pipe
                    try? listing.run()
                    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    listing.waitUntilExit()
                    if output.contains(secret) { return true }
                }
                return false
            }
            try await run.act(.typeText(text: secret, target: run.target(field)))
            await run.fixture.settle()
            watcher.cancel()
            let leaked = await watcher.value
            let expected = SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
            let landed = run.fixture.last("password")?.hasPrefix(expected) == true
            return Outcome(pass: landed && !leaked, detail: "landed=\(landed) leakedOnArgv=\(leaked)")
        }
    }

    func testMultilineTextLandsExactly() async throws {
        let text = "line one\nline two\n\tindented 👋"
        try await scenario("type-multiline") { run in
            try await run.read()
            try await run.type(text, into: "Notes")
            await run.fixture.settle()
            let value = run.fixture.decodedLast("notes")
            return Outcome(pass: value == text, detail: "got \(value.map { $0.debugDescription } ?? "nil")")
        }
    }

    func testDictationInsertGoesIntoTheFocusedField() async throws {
        try await scenario("insert-focused") { run in
            try await run.read()
            try await run.type("a", into: "Name")
            await run.fixture.settle(0.4)
            _ = try await run.driver.insertText(" dictated", target: run.fixture.hint, sessionID: run.session)
            await run.fixture.settle()
            let value = run.fixture.decodedLast("name")
            return Outcome(pass: value == "a dictated", detail: "got \(value ?? "nil")")
        }
    }

    func testCheckboxTogglesExactlyOnce() async throws {
        try await scenario("checkbox") { run in
            try await run.read()
            try await run.click("Dark Mode")
            await run.fixture.settle(1.2)
            let lines = run.fixture.lines("checkbox")
            return Outcome(pass: lines.count == 1 && lines[0].hasPrefix("checkbox on"), detail: "\(lines)")
        }
    }

    func testPopupValueIsChosenWithoutAMenuLeftOpen() async throws {
        try await scenario("popup-set") { run in
            try await run.read()
            let popup = try XCTUnwrap(run.elements.first { $0.label == "Size" || $0.value == "Small" }, "no popup")
            try await run.act(.setValue(value: "Large", target: run.target(popup)))
            await run.fixture.settle()
            let lines = run.fixture.lines("popup")
            return Outcome(pass: lines.last?.hasPrefix("popup Large") == true, detail: "\(lines)")
        }
    }

    func testPopupChosenByClickingTheMenuItem() async throws {
        try await scenario("popup-click") { run in
            try await run.read()
            let popup = try XCTUnwrap(run.elements.first { $0.label == "Size" || $0.value == "Small" }, "no popup")
            try await run.act(.click(run.target(popup)))
            await run.fixture.settle(0.6)
            try await run.read()
            try await run.click("Large")
            await run.fixture.settle()
            let lines = run.fixture.lines("popup")
            return Outcome(pass: lines.last?.hasPrefix("popup Large") == true, detail: "\(lines)")
        }
    }

    func testCanvasPointClickLandsInTheBackground() async throws {
        try await scenario("canvas-click") { run in
            try await run.read()
            try await run.act(.click(.point(try run.pixels(220, 400))))
            _ = await run.fixture.wait(for: "canvas-click")
            let parts = (run.fixture.lines("canvas-click").first ?? "").split(separator: " ").compactMap { Double($0) }
            let pass = parts.count == 3 && abs(parts[0] - 200) <= 6 && abs(parts[1] - 100) <= 6 && run.fixture.lines("canvas-click").count == 1
            return Outcome(pass: pass, detail: "\(run.fixture.lines("canvas-click"))")
        }
    }

    func testCanvasPointClickLandsInTheForegroundScope() async throws {
        try await scenario("canvas-click-fg", foreground: true) { run in
            try await run.read()
            try await run.act(.click(.point(try run.pixels(220, 400))))
            _ = await run.fixture.wait(for: "canvas-click")
            let lines = run.fixture.lines("canvas-click")
            let parts = (lines.first ?? "").split(separator: " ").compactMap { Double($0) }
            let pass = lines.count == 1 && parts.count == 3 && abs(parts[0] - 200) <= 6 && abs(parts[1] - 100) <= 6
            return Outcome(pass: pass, detail: "\(lines)")
        }
    }

    func testCanvasDragLandsInTheForegroundScope() async throws {
        try await scenario("canvas-drag-fg", foreground: true) { run in
            try await run.read()
            try await run.act(.drag(from: try run.pixels(60, 330), to: try run.pixels(360, 470), durationMilliseconds: 300, steps: 12))
            _ = await run.fixture.wait(for: "canvas-drag")
            let parts = (run.fixture.lines("canvas-drag").first ?? "").split(separator: " ").compactMap { Double($0) }
            let pass = parts.count == 4 && abs(parts[0] - 40) <= 6 && abs(parts[1] - 30) <= 6 && abs(parts[2] - 340) <= 6 && abs(parts[3] - 170) <= 6
            return Outcome(pass: pass, detail: "\(run.fixture.lines("canvas"))")
        }
    }

    func testCanvasDoubleClickLandsAsOneDoubleClick() async throws {
        try await scenario("canvas-double") { run in
            try await run.read()
            try await run.act(.doubleClick(.point(try run.pixels(120, 350))))
            await run.fixture.settle()
            let lines = run.fixture.lines("canvas-click")
            return Outcome(pass: lines.last?.hasSuffix(" 2") == true, detail: "\(lines)")
        }
    }

    func testCanvasDragLandsInTheBackground() async throws {
        try await scenario("canvas-drag") { run in
            try await run.read()
            try await run.act(.drag(from: try run.pixels(60, 330), to: try run.pixels(360, 470), durationMilliseconds: 300, steps: 12))
            _ = await run.fixture.wait(for: "canvas-drag")
            let parts = (run.fixture.lines("canvas-drag").first ?? "").split(separator: " ").compactMap { Double($0) }
            let pass = parts.count == 4 && abs(parts[0] - 40) <= 6 && abs(parts[1] - 30) <= 6 && abs(parts[2] - 340) <= 6 && abs(parts[3] - 170) <= 6
            return Outcome(pass: pass, detail: "\(run.fixture.lines("canvas"))")
        }
    }

    func testBusyAppIsNotClickedTwiceAndRecovers() async throws {
        try await scenario("busy-app") { run in
            try await run.read()
            var slowError: Error?
            do {
                try await run.click("Slow", role: .button)
            } catch {
                slowError = error
            }
            _ = await run.fixture.wait(for: "slow done", timeout: 8)
            try await run.read()
            try await run.click("Works", role: .button)
            await run.fixture.settle(1.5)
            let slow = run.fixture.lines("slow begin").count
            let works = run.fixture.lines("works").count
            return Outcome(pass: slow == 1 && works == 1, detail: "slow=\(slow) works=\(works) slowError=\(slowError.map { String(describing: $0) } ?? "none")")
        }
    }

    func testDelayedRelabelIsNotTreatedAsNoEffect() async throws {
        try await scenario("delayed-relabel") { run in
            try await run.read()
            try await run.click("Later", role: .button)
            await run.fixture.settle(2)
            let lines = run.fixture.lines("later")
            return Outcome(pass: lines.count == 1, detail: "\(lines)")
        }
    }

    func testSheetButtonIsReachedAfterItOpens() async throws {
        try await scenario("sheet") { run in
            try await run.read()
            try await run.click("Open Sheet", role: .button)
            await run.fixture.settle(0.8)
            try await run.read()
            try await run.click("Continue", role: .button)
            await run.fixture.settle()
            let opened = run.fixture.lines("sheet open").count
            let closed = run.fixture.lines("sheet continue").count
            return Outcome(pass: opened == 1 && closed == 1, detail: "\(run.fixture.lines("sheet"))")
        }
    }

    func testTableRowIsSelected() async throws {
        try await scenario("table-select") { run in
            try await run.read()
            try await run.click("Item 3")
            await run.fixture.settle()
            let lines = run.fixture.lines("select")
            return Outcome(pass: lines.last?.hasPrefix("select 3") == true, detail: "\(lines)")
        }
    }

    func testTableRowOffScreenIsReachedAfterScrolling() async throws {
        try await scenario("table-scroll") { run in
            try await run.read()
            let anchor = try run.element("Item 2")
            try await run.act(.scroll(direction: .down, amount: 15, by: nil, target: run.target(anchor)))
            await run.fixture.settle(0.6)
            try await run.read()
            let visible = run.elements.compactMap { element -> Int? in
                guard let text = element.label ?? element.value ?? run.capture?.elementDetails[element.stableID]?.value, text.hasPrefix("Item ") else { return nil }
                return Int(text.dropFirst(5))
            }
            let deepest = visible.max() ?? 0
            guard deepest >= 20 else { return Outcome(pass: false, detail: "scroll did not move: max visible Item \(deepest)") }
            try await run.click("Item \(deepest - 1)")
            await run.fixture.settle()
            let lines = run.fixture.lines("select")
            return Outcome(pass: lines.last?.hasPrefix("select \(deepest - 1)") == true, detail: "target Item \(deepest - 1) \(lines)")
        }
    }

    func testWebInputTakesText() async throws {
        let text = "héllo web ✓"
        try await scenario("web-type") { run in
            try await run.read()
            try await run.type(text, into: "Search")
            await run.fixture.settle()
            let value = run.fixture.decodedLast("web-input")
            return Outcome(pass: value == text, detail: "got \(value ?? "nil")")
        }
    }

    func testWebButtonAndLinkLandOnce() async throws {
        try await scenario("web-click") { run in
            try await run.read()
            try await run.click("Go", role: .button)
            await run.fixture.settle(0.6)
            try await run.click("More results")
            await run.fixture.settle()
            let go = run.fixture.lines("web-go").count
            let link = run.fixture.lines("web-link").count
            return Outcome(pass: go == 1 && link == 1, detail: "go=\(go) link=\(link)")
        }
    }

    func testSelectAllThenTypeReplacesTheText() async throws {
        try await scenario("hotkey-replace") { run in
            try await run.read()
            try await run.type("old text", into: "Name")
            await run.fixture.settle(0.4)
            try await run.act(.hotkey(keys: ["cmd", "a"], target: run.target(try run.element("Name"))))
            await run.fixture.settle(0.3)
            try await run.act(.typeText(text: "new", target: nil))
            await run.fixture.settle()
            let value = run.fixture.decodedLast("name")
            return Outcome(pass: value == "new", detail: "got \(value ?? "nil")")
        }
    }

    func testRepeatedClicksAreCountedExactly() async throws {
        try await scenario("burst-20", repeats: max(1, environment.repeats / 2)) { run in
            try await run.read()
            for _ in 0..<20 {
                try await run.click("Works", role: .button)
            }
            await run.fixture.settle()
            let count = run.fixture.lines("works").count
            return Outcome(pass: count == 20, detail: "works=\(count)")
        }
    }

    func testRepeatedCaptures() async throws {
        try await scenario("capture-20", repeats: max(1, environment.repeats / 2)) { run in
            for _ in 0..<20 {
                try await run.read()
            }
            let count = run.elements.count
            return Outcome(pass: count > 10, detail: "elements=\(count)")
        }
    }

    func testTargetAppQuittingFailsFast() async throws {
        try await scenario("app-quit") { run in
            try await run.read()
            run.fixture.app.forceTerminate()
            try await Task.sleep(for: .milliseconds(500))
            let started = Date()
            var failure: Error?
            do {
                try await run.click("Works", role: .button)
            } catch {
                failure = error
            }
            let seconds = Date().timeIntervalSince(started)
            return Outcome(pass: failure != nil && seconds < 4, detail: "\(String(format: "%.2f", seconds)) s \(failure.map { String(describing: $0) } ?? "no error")")
        }
    }

    func testParallelWorkersEachLandExactly() async throws {
        let fixtures = try await withThrowingTaskGroup(of: Fixture.self) { group in
            for index in 0..<3 {
                group.addTask { try await Fixture.launch(self.environment.fixture, title: "Perry Torture Fixture \(index)") }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        defer { fixtures.forEach { $0.quit() } }
        let before = Self.observeUser()
        let started = Date()
        let results = try await withThrowingTaskGroup(of: (Int, String?).self) { group in
            for fixture in fixtures {
                let driver = try makeDriver()
                group.addTask {
                    let run = TortureRun(driver: driver, fixture: fixture)
                    var problem: String?
                    do {
                        try await run.read()
                        for _ in 0..<10 {
                            try await run.click("Works", role: .button)
                        }
                        try await run.type("parallel", into: "Name")
                    } catch {
                        problem = String(describing: error)
                    }
                    await fixture.settle()
                    await driver.shutdown()
                    return (fixture.lines("works").count, problem ?? (fixture.decodedLast("name") == "parallel" ? nil : "name=\(fixture.decodedLast("name") ?? "nil")"))
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        let total = Date().timeIntervalSince(started) * 1000
        let pass = results.allSatisfy { $0.0 == 10 && $0.1 == nil } && Self.observeUser() == before
        record("parallel-3", rep: 0, outcome: Outcome(pass: pass, detail: "\(results)"), run: nil, error: nil, userDisturbed: Self.observeUser() != before, total: total)
        XCTAssertTrue(pass, "\(driverLabel) parallel: \(results)")
    }
}
