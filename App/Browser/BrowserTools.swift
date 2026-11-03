import AppKit
import Foundation
import PerryBrain
import PerryCore
import PerryRuntimes

struct BrowserTools {
    let lane: BrowserLane
    let worker: ToolWorkerContext

    private static let textLimit = 20_000

    var executors: [any ToolExecutor] {
        let lane = lane
        let worker = worker
        return [
            BrowserTool(
                name: "browser.connect",
                description: "Let Perry into the user's Chrome, Edge, Brave or Arc when the browser.* tools say remote debugging is off. With the user's approval it opens chrome://inspect/#remote-debugging in that browser and ticks “Allow remote debugging for this browser instance”, then waits while the user clicks Allow on the browser's own prompt. name: the browser app's name, e.g. Google Chrome; omit it to use the browser whose window is in front.",
                properties: ["name": Self.string("Browser app name, e.g. Google Chrome")], tier: .orange
            ) { arguments, run in
                [.text(try await Self.connect(name: arguments["name"]?.stringValue, lane: lane, worker: worker, run: run))]
            },
            BrowserTool(
                name: "browser.page",
                description: "For web pages in Chrome, Edge, Brave or Arc, use the browser.* tools instead of screen.observe and ui.*: they read the page itself and act in the background. browser.page returns the attached tab's URL, title, viewport size, scroll position and page size, or the open JavaScript dialog if one blocks the page. The first browser call attaches to the tab in front.",
                properties: [:], readOnly: true
            ) { _, run in
                if let dialog = try await lane.dialog(run: run) {
                    return [.text("dialog open: \(Self.json(dialog)). Answer it with browser.dialog.")]
                }
                let tab = try await lane.currentTab(run: run)
                let info = try await Self.evaluate(
                    "JSON.stringify({url:location.href,title:document.title,width:innerWidth,height:innerHeight,scrollX:scrollX,scrollY:scrollY,pageWidth:document.documentElement.scrollWidth,pageHeight:document.documentElement.scrollHeight})",
                    lane: lane, run: run
                )
                return [.text("tab \(tab.id): \(info.stringValue ?? Self.json(info))")]
            },
            BrowserTool(
                name: "browser.screenshot",
                description: "Screenshot the attached tab's viewport. Image pixels are page CSS pixels, the same x, y that browser.click, browser.hover, browser.drag and browser.scroll take.",
                properties: [:], readOnly: true, vision: true
            ) { _, run in
                let metrics = try await lane.command("Page.getLayoutMetrics", run: run)
                let viewport = metrics["cssVisualViewport"]
                let ratio = try await Self.evaluate("window.devicePixelRatio", lane: lane, run: run).doubleValue ?? 1
                let width = viewport?["clientWidth"]?.doubleValue ?? 1280
                let height = viewport?["clientHeight"]?.doubleValue ?? 800
                let shot = try await lane.command("Page.captureScreenshot", [
                    "format": .string("jpeg"), "quality": .number(80),
                    "clip": .object([
                        "x": viewport?["pageX"] ?? .number(0), "y": viewport?["pageY"] ?? .number(0),
                        "width": .number(width), "height": .number(height), "scale": .number(1 / max(ratio, 0.1)),
                    ]),
                ], run: run, timeout: .seconds(30))
                guard let encoded = shot["data"]?.stringValue, let data = Data(base64Encoded: encoded) else {
                    throw BrowserError.chrome("Chrome returned no screenshot.")
                }
                let tab = try await lane.currentTab(run: run)
                return [.text("\(tab.title) — \(tab.url) (\(Int(width))×\(Int(height)) CSS px)"), .image(data: data, mimeType: "image/jpeg")]
            },
            BrowserTool(
                name: "browser.text",
                description: "Read the visible text of the attached tab, or of the first element matching a CSS selector. Up to 20,000 characters.",
                properties: ["selector": Self.string("CSS selector; omit for the whole page")], readOnly: true
            ) { arguments, run in
                let selector = arguments["selector"]?.stringValue
                let target = selector.map { "document.querySelector(\(Self.literal($0)))" } ?? "document.body"
                let text = try await Self.evaluate("(\(target)||{innerText:''}).innerText", lane: lane, run: run).stringValue ?? ""
                return [.text(text.count > Self.textLimit ? String(text.prefix(Self.textLimit)) + "\n…truncated" : text)]
            },
            BrowserTool(
                name: "browser.tabs",
                description: "List the browser's open tabs with their ids, titles and URLs, and which one Perry is attached to.",
                properties: [:], readOnly: true
            ) { _, run in
                let current = try? await lane.currentTab(run: run).id
                let lines = try await lane.tabs().filter { !BrowserLane.isInternal($0.url) || $0.id == current }.map {
                    BrowserLane.isProtected($0) ? "  \($0.id)  (protected page)" : "\($0.id == current ? "* " : "  ")\($0.id)  \($0.title)  \($0.url)"
                }
                return [.text(lines.isEmpty ? "no tabs" : lines.joined(separator: "\n"))]
            },
            BrowserTool(
                name: "browser.open",
                description: "Open a URL in a new background tab and attach to it, without changing the tab the user sees.",
                properties: ["url": Self.string("Absolute URL")], required: ["url"], tier: .yellow
            ) { arguments, run in
                let url = arguments["url"]?.stringValue ?? "about:blank"
                let created = try await lane.devTools.send("Target.createTarget", ["url": .string("about:blank"), "background": .bool(true)])
                guard let target = created["targetId"]?.stringValue else { throw BrowserError.chrome("Chrome didn’t open a tab.") }
                try await lane.attach(run: run, to: target)
                return [.text(try await Self.navigate(url, lane: lane, run: run))]
            },
            BrowserTool(
                name: "browser.switch",
                description: "Attach to another tab by id, URL fragment or title. show: true also brings it to the front for the user.",
                properties: ["tab": Self.string("Tab id, URL fragment or title"), "show": .object(["type": .string("boolean")])],
                required: ["tab"], tier: .yellow
            ) { arguments, run in
                let tab = try await lane.resolve(arguments["tab"]?.stringValue ?? "")
                try await lane.attach(run: run, to: tab.id)
                if arguments["show"]?.boolValue == true {
                    _ = try await lane.devTools.send("Target.activateTarget", ["targetId": .string(tab.id)])
                }
                return [.text("attached to \(tab.id): \(tab.title) — \(tab.url)")]
            },
            BrowserTool(
                name: "browser.close",
                description: "Close a tab by id, URL fragment or title. Close only tabs you opened.",
                properties: ["tab": Self.string("Tab id, URL fragment or title")], required: ["tab"], tier: .yellow
            ) { arguments, run in
                let tab = try await lane.resolve(arguments["tab"]?.stringValue ?? "")
                if (try? await lane.currentTab(run: run).id) == tab.id { await lane.release(run: run) }
                _ = try await lane.devTools.send("Target.closeTarget", ["targetId": .string(tab.id)])
                return [.text("closed \(tab.title)")]
            },
            BrowserTool(
                name: "browser.goto",
                description: "Load a URL in the attached tab and wait for it to finish loading.",
                properties: ["url": Self.string("Absolute URL")], required: ["url"], tier: .yellow
            ) { arguments, run in
                [.text(try await Self.navigate(arguments["url"]?.stringValue ?? "", lane: lane, run: run))]
            },
            BrowserTool(
                name: "browser.click",
                description: "Click at x, y in page CSS pixels (as in browser.screenshot). Real mouse events: hover, press, release. count 2 double-clicks; button right opens a context menu.",
                properties: [
                    "x": Self.number, "y": Self.number,
                    "button": .object(["type": .string("string"), "enum": .array(["left", "right", "middle"].map(JSONValue.string))]),
                    "count": .object(["type": .string("integer")]),
                ],
                required: ["x", "y"], tier: .yellow
            ) { arguments, run in
                let x = arguments["x"] ?? .number(0), y = arguments["y"] ?? .number(0)
                let button = JSONValue.string(arguments["button"]?.stringValue ?? "left")
                let count = max(1, min(3, Int(arguments["count"]?.doubleValue ?? 1)))
                _ = try await lane.command("Input.dispatchMouseEvent", ["type": .string("mouseMoved"), "x": x, "y": y], run: run)
                for click in 1...count {
                    for type in ["mousePressed", "mouseReleased"] {
                        _ = try await lane.command("Input.dispatchMouseEvent", [
                            "type": .string(type), "x": x, "y": y, "button": button, "clickCount": .number(Double(click)),
                        ], run: run)
                    }
                }
                return [.text("clicked \(Self.json(x)), \(Self.json(y))")]
            },
            BrowserTool(
                name: "browser.hover",
                description: "Move the mouse to x, y in page CSS pixels without clicking, for hover menus and tooltips.",
                properties: ["x": Self.number, "y": Self.number], required: ["x", "y"], tier: .yellow
            ) { arguments, run in
                _ = try await lane.command("Input.dispatchMouseEvent", ["type": .string("mouseMoved"), "x": arguments["x"] ?? .number(0), "y": arguments["y"] ?? .number(0)], run: run)
                return [.text("hovering")]
            },
            BrowserTool(
                name: "browser.drag",
                description: "Drag from one point to another in page CSS pixels with the mouse held down. Works for sliders, canvases and HTML drag and drop.",
                properties: ["fromX": Self.number, "fromY": Self.number, "toX": Self.number, "toY": Self.number],
                required: ["fromX", "fromY", "toX", "toY"], tier: .yellow
            ) { arguments, run in
                try await Self.drag(arguments, lane: lane, run: run)
                return [.text("dragged")]
            },
            BrowserTool(
                name: "browser.type",
                description: "Type text into the focused element (click it first). keys: true sends one key event per character, for fields that format or validate on each keystroke.",
                properties: ["text": Self.string("Text to type"), "keys": .object(["type": .string("boolean")])],
                required: ["text"], tier: .yellow
            ) { arguments, run in
                let text = arguments["text"]?.stringValue ?? ""
                if arguments["keys"]?.boolValue == true {
                    for character in text {
                        let key = character == "\n" ? "Enter" : String(character)
                        try await Self.press(BrowserKeys.stroke(key), lane: lane, run: run)
                    }
                } else {
                    _ = try await lane.command("Input.insertText", ["text": .string(text)], run: run)
                }
                return [.text("typed \(text.count) characters")]
            },
            BrowserTool(
                name: "browser.key",
                description: "Press a key in the attached tab: Enter, Tab, Escape, Backspace, Delete, arrows, Home, End, PageUp, PageDown, Space or one character, with optional modifiers (cmd, ctrl, alt, shift).",
                properties: ["key": Self.string("Key name or character"), "modifiers": .object(["type": .string("array"), "items": .object(["type": .string("string")])])],
                required: ["key"], tier: .yellow
            ) { arguments, run in
                let modifiers = BrowserKeys.modifiers(arguments["modifiers"]?.arrayValue?.compactMap(\.stringValue) ?? [])
                try await Self.press(BrowserKeys.stroke(arguments["key"]?.stringValue ?? "", modifiers: modifiers), lane: lane, run: run)
                return [.text("pressed")]
            },
            BrowserTool(
                name: "browser.scroll",
                description: "Scroll with the mouse wheel at x, y in page CSS pixels (default: viewport centre). amount is in CSS pixels (default 600).",
                properties: [
                    "direction": .object(["type": .string("string"), "enum": .array(["up", "down", "left", "right"].map(JSONValue.string))]),
                    "amount": Self.number, "x": Self.number, "y": Self.number,
                ],
                required: ["direction"], tier: .yellow
            ) { arguments, run in
                let amount = arguments["amount"]?.doubleValue ?? 600
                let direction = arguments["direction"]?.stringValue ?? "down"
                var point = [arguments["x"], arguments["y"]]
                if point.contains(where: { $0 == nil }) {
                    let center = try await Self.evaluate("[innerWidth/2,innerHeight/2]", lane: lane, run: run).arrayValue
                    point = [arguments["x"] ?? center?.first, arguments["y"] ?? center?.last]
                }
                _ = try await lane.command("Input.dispatchMouseEvent", [
                    "type": .string("mouseWheel"),
                    "x": point[0] ?? .number(400), "y": point[1] ?? .number(300),
                    "deltaX": .number(direction == "right" ? amount : direction == "left" ? -amount : 0),
                    "deltaY": .number(direction == "down" ? amount : direction == "up" ? -amount : 0),
                ], run: run)
                let position = try await Self.evaluate("JSON.stringify([scrollX,scrollY])", lane: lane, run: run)
                return [.text("scrolled; window scroll is now \(position.stringValue ?? "")")]
            },
            BrowserTool(
                name: "browser.js",
                description: "Run JavaScript in the attached tab and return its JSON value (promises are awaited; a top-level return works). frame: a URL fragment of an iframe to run inside it. Use it to read the DOM, find element positions, or act when the mouse can’t.",
                properties: ["expression": Self.string("JavaScript"), "frame": Self.string("URL fragment of an iframe")],
                required: ["expression"], tier: .orange
            ) { arguments, run in
                let value = try await Self.evaluate(arguments["expression"]?.stringValue ?? "", frame: arguments["frame"]?.stringValue, lane: lane, run: run)
                let text = value.stringValue ?? Self.json(value)
                return [.text(text.count > Self.textLimit ? String(text.prefix(Self.textLimit)) + "\n…truncated" : text)]
            },
            BrowserTool(
                name: "browser.wait",
                description: "Wait until the page has loaded and, if given, a CSS selector exists or some text appears. Up to 30 seconds.",
                properties: ["selector": Self.string("CSS selector"), "text": Self.string("Text to wait for"), "seconds": Self.number],
                readOnly: true
            ) { arguments, run in
                let seconds = min(30, arguments["seconds"]?.doubleValue ?? 10)
                var check = "document.readyState==='complete'"
                if let selector = arguments["selector"]?.stringValue { check += "&&!!document.querySelector(\(Self.literal(selector)))" }
                if let text = arguments["text"]?.stringValue { check += "&&document.body.innerText.includes(\(Self.literal(text)))" }
                let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
                while ContinuousClock.now < deadline {
                    if try await Self.evaluate(check, lane: lane, run: run).boolValue == true { return [.text("ready")] }
                    try await Task.sleep(for: .milliseconds(250))
                }
                return [.text("still waiting after \(Int(seconds)) s")]
            },
            BrowserTool(
                name: "browser.dialog",
                description: "Answer the page's open alert, confirm or prompt. accept: true clicks OK; text fills a prompt.",
                properties: ["accept": .object(["type": .string("boolean")]), "text": Self.string("Prompt answer")],
                required: ["accept"], tier: .yellow
            ) { arguments, run in
                var params: [String: JSONValue] = ["accept": .bool(arguments["accept"]?.boolValue ?? true)]
                if let text = arguments["text"]?.stringValue { params["promptText"] = .string(text) }
                _ = try await lane.command("Page.handleJavaScriptDialog", params, run: run)
                return [.text("answered")]
            },
        ]
    }

    private static let inspectURL = URL(string: "chrome://inspect/#remote-debugging")!

    private static func connect(name: String?, lane: BrowserLane, worker: ToolWorkerContext, run: UUID) async throws -> String {
        do {
            _ = try await lane.devTools.send("Browser.getVersion", timeout: .seconds(120))
            return "Perry can already use the browser."
        } catch BrowserError.remoteDebuggingOff, BrowserError.notRunning {
        }
        let found = await MainActor.run { () -> (ChromeEndpoint.Browser, URL)? in
            let apps = NSWorkspace.shared.runningApplications
            let running = apps.compactMap { app in app.bundleIdentifier.map { ChromeEndpoint.RunningApp(bundleID: $0, name: app.localizedName ?? "") } }
            let order = ChromeEndpoint.onScreenWindows().map(\.bundleID)
            guard let browser = ChromeEndpoint.browser(named: name, running: running, windowOrder: order),
                  let url = apps.first(where: { $0.bundleIdentifier == browser.bundleID })?.bundleURL else { return nil }
            return (browser, url)
        }
        guard let found else {
            throw BrowserError.chrome(name.map { "\($0) isn’t open, or isn’t a Chrome-family browser." } ?? "Open Chrome, Edge, Brave or Arc and bring it to the front, or name the browser.")
        }
        let (browser, appURL) = found
        let portFile = ChromeEndpoint.activePortFile(for: browser)
        let started = Date()
        func portIsFresh() -> Bool {
            let modified = (try? FileManager.default.attributesOfItem(atPath: portFile.path))?[.modificationDate] as? Date
            return modified.map { $0 >= started.addingTimeInterval(-1) } ?? false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.open([inspectURL], withApplicationAt: appURL, configuration: configuration)
        try await worker.withWorker(runID: run, resources: [.application(browser.bundleID.lowercased())]) { handle in
            let hint = ScreenTargetHint(bundleID: browser.bundleID)
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            var page: ScreenCapturedWindow?
            while page == nil, ContinuousClock.now < deadline {
                let captured = try? await handle.capture(target: hint, includeScreenshot: false)
                if captured?.accessibilitySnapshot?.contains("Allow remote debugging for this browser instance") == true { page = captured }
                else { try await Task.sleep(for: .milliseconds(300)) }
            }
            guard page != nil else { throw BrowserError.chrome("The browser didn’t show its remote debugging page.") }
            _ = try? await handle.execute(ComputerAction(stepID: "inspect-section", operation: .click(.label("Remote debugging", point: nil))))
            _ = try await handle.execute(ComputerAction(stepID: "inspect-allow", operation: .click(.label("Allow remote debugging for this browser instance", point: nil))))
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !portIsFresh(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        guard portIsFresh() else {
            throw BrowserError.chrome("I opened chrome://inspect/#remote-debugging but couldn’t confirm the switch turned on. Ask the user to tick “Allow remote debugging for this browser instance” there.")
        }
        do {
            _ = try await lane.devTools.send("Browser.getVersion", timeout: .seconds(120))
        } catch BrowserError.timedOut {
            throw BrowserError.chrome("Remote debugging is on. The browser is asking the user to click Allow; ask them to click it, then try again.")
        }
        let inspectTabs = try await lane.tabs().filter { $0.url.hasPrefix("chrome://inspect") }
        for tab in inspectTabs {
            _ = try? await lane.devTools.send("Target.closeTarget", ["targetId": .string(tab.id)])
        }
        return "Remote debugging is on and the user allowed Perry in. The browser.* tools work now."
    }

    private static let number: JSONValue = .object(["type": .string("number")])

    private static func string(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func literal(_ text: String) -> String {
        String(decoding: (try? JSONEncoder().encode(text)) ?? Data("\"\"".utf8), as: UTF8.self)
    }

    private static func json(_ value: JSONValue) -> String {
        String(decoding: (try? JSONEncoder().encode(value)) ?? Data(), as: UTF8.self)
    }

    private static func navigate(_ url: String, lane: BrowserLane, run: UUID) async throws -> String {
        let result = try await lane.command("Page.navigate", ["url": .string(url)], run: run, timeout: .seconds(30))
        if let failure = result["errorText"]?.stringValue { throw BrowserError.chrome("The page didn’t load: \(failure)") }
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            if (try? await evaluate("document.readyState", lane: lane, run: run).stringValue) == "complete" { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        let tab = try await lane.currentTab(run: run)
        try BrowserLane.ensureAllowed(tab)
        return "loaded \(tab.title) — \(tab.url)"
    }

    static func evaluate(_ expression: String, frame: String? = nil, lane: BrowserLane, run: UUID) async throws -> JSONValue {
        guard let frame else {
            return try await runtimeEvaluate(expression) { params in try await lane.command("Runtime.evaluate", params, run: run, timeout: .seconds(30)) }
        }
        _ = try await lane.session(run: run)
        let targets = try await lane.devTools.send("Target.getTargets")["targetInfos"]?.arrayValue ?? []
        if let target = targets.first(where: { $0["type"]?.stringValue == "iframe" && ($0["url"]?.stringValue ?? "").contains(frame) })?["targetId"] {
            let session = try await lane.devTools.send("Target.attachToTarget", ["targetId": target, "flatten": .bool(true)])["sessionId"]?.stringValue
            defer { if let session { Task { _ = try? await lane.devTools.send("Target.detachFromTarget", ["sessionId": .string(session)]) } } }
            return try await runtimeEvaluate(expression) { params in try await lane.devTools.send("Runtime.evaluate", params, session: session, timeout: .seconds(30)) }
        }
        let tree = try await lane.command("Page.getFrameTree", run: run)
        guard let frameID = frameID(in: tree["frameTree"], matching: frame) else { throw BrowserError.chrome("No frame’s URL contains “\(frame)”.") }
        let world = try await lane.command("Page.createIsolatedWorld", ["frameId": .string(frameID), "worldName": .string("perry"), "grantUniveralAccess": .bool(true)], run: run)
        guard let context = world["executionContextId"] else { throw BrowserError.chrome("Chrome couldn’t open that frame.") }
        return try await runtimeEvaluate(expression) { params in
            var params = params
            params["contextId"] = context
            return try await lane.command("Runtime.evaluate", params, run: run, timeout: .seconds(30))
        }
    }

    private static func frameID(in node: JSONValue?, matching fragment: String) -> String? {
        guard let node else { return nil }
        if let url = node["frame"]?["url"]?.stringValue, url.contains(fragment), node["frame"]?["parentId"] != nil {
            return node["frame"]?["id"]?.stringValue
        }
        for child in node["childFrames"]?.arrayValue ?? [] {
            if let found = frameID(in: child, matching: fragment) { return found }
        }
        return nil
    }

    private static func runtimeEvaluate(_ expression: String, send: ([String: JSONValue]) async throws -> JSONValue) async throws -> JSONValue {
        let options: [String: JSONValue] = ["returnByValue": .bool(true), "awaitPromise": .bool(true)]
        var response = try await send(options.merging(["expression": .string(expression)]) { $1 })
        if exceptionText(response)?.contains("Illegal return statement") == true {
            response = try await send(options.merging(["expression": .string("(async function(){\(expression)\n})()")]) { $1 })
        }
        if let failure = exceptionText(response) { throw BrowserError.chrome("JavaScript failed: \(failure)") }
        let result = response["result"]
        if let value = result?["value"] { return value }
        if let unserializable = result?["unserializableValue"]?.stringValue { return .string(unserializable) }
        return .null
    }

    private static func exceptionText(_ response: JSONValue) -> String? {
        guard let details = response["exceptionDetails"] else {
            return response["result"]?["subtype"]?.stringValue == "error" ? response["result"]?["description"]?.stringValue ?? "error" : nil
        }
        return details["exception"]?["description"]?.stringValue ?? details["text"]?.stringValue ?? "error"
    }

    private static func press(_ stroke: BrowserKeys.Stroke, lane: BrowserLane, run: UUID) async throws {
        for event in BrowserKeys.events(for: stroke) {
            _ = try await lane.command("Input.dispatchKeyEvent", event, run: run)
        }
    }

    private static func drag(_ arguments: JSONValue, lane: BrowserLane, run: UUID) async throws {
        let from = (arguments["fromX"]?.doubleValue ?? 0, arguments["fromY"]?.doubleValue ?? 0)
        let to = (arguments["toX"]?.doubleValue ?? 0, arguments["toY"]?.doubleValue ?? 0)
        func mouse(_ type: String, _ point: (Double, Double), buttons: Int) async throws {
            _ = try await lane.command("Input.dispatchMouseEvent", [
                "type": .string(type), "x": .number(point.0), "y": .number(point.1),
                "button": .string(type == "mouseMoved" && buttons == 0 ? "none" : "left"), "buttons": .number(Double(buttons)), "clickCount": .number(1),
            ], run: run)
        }
        let session = try await lane.session(run: run)
        _ = try await lane.command("Input.setInterceptDrags", ["enabled": .bool(true)], run: run)
        do {
            try await mouse("mouseMoved", from, buttons: 0)
            try await mouse("mousePressed", from, buttons: 1)
            let steps = 12
            for step in 1...steps {
                let t = Double(step) / Double(steps)
                try await mouse("mouseMoved", (from.0 + (to.0 - from.0) * t, from.1 + (to.1 - from.1) * t), buttons: 1)
                try await Task.sleep(for: .milliseconds(16))
            }
            if let data = await lane.devTools.takeDragData(session: session) {
                for type in ["dragEnter", "dragOver", "drop"] {
                    _ = try await lane.command("Input.dispatchDragEvent", ["type": .string(type), "x": .number(to.0), "y": .number(to.1), "data": data], run: run)
                }
            }
            try await mouse("mouseReleased", to, buttons: 0)
        } catch {
            _ = try? await lane.command("Input.setInterceptDrags", ["enabled": .bool(false)], run: run)
            throw error
        }
        _ = try await lane.command("Input.setInterceptDrags", ["enabled": .bool(false)], run: run)
    }
}

private struct BrowserTool: ToolExecutor {
    let spec: ToolSpec
    let body: @Sendable (JSONValue, UUID) async throws -> [ModelContentPart]

    init(
        name: String,
        description: String,
        properties: [String: JSONValue],
        required: [String] = [],
        tier: TrustTier = .green,
        readOnly: Bool = false,
        vision: Bool = false,
        body: @escaping @Sendable (JSONValue, UUID) async throws -> [ModelContentPart]
    ) {
        var schema: [String: JSONValue] = ["type": .string("object"), "properties": .object(properties)]
        if !required.isEmpty { schema["required"] = .array(required.map(JSONValue.string)) }
        spec = ToolSpec(
            name: name, description: description, inputSchema: .object(schema), tier: tier,
            surfaces: [.agent], readOnly: readOnly, requiredCapabilities: vision ? [.tools, .vision] : [.tools]
        )
        self.body = body
    }

    func run(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        ToolResult(callID: call.id, content: try await body(call.arguments, context.runID))
    }
}
