import AppKit
import Foundation
import PerryBrain

enum BrowserError: Error, Equatable, LocalizedError {
    case remoteDebuggingOff
    case notRunning
    case permissionBlocked
    case noTab
    case protectedPage
    case timedOut(String)
    case connectionLost
    case chrome(String)

    var errorDescription: String? {
        switch self {
        case .remoteDebuggingOff:
            return "Remote debugging is off in the browser. Call browser.connect: it asks the user, then turns it on."
        case .notRunning:
            return "No browser is letting Perry in. If Chrome, Edge, Brave or Arc is open, call browser.connect: it asks the user, then turns on remote debugging."
        case .permissionBlocked:
            return "Chrome is waiting for you to click Allow on its “Allow remote debugging?” prompt."
        case .noTab:
            return "There’s no web page open in the browser."
        case .protectedPage:
            return "I won’t look at or use a page that holds sensitive information."
        case .timedOut(let method):
            return "The browser took too long to answer (\(method))."
        case .connectionLost:
            return "The connection to the browser closed. Try again."
        case .chrome(let message):
            return message
        }
    }
}

enum ChromeEndpoint {
    struct Browser: Equatable {
        let profile: String
        let bundleID: String
    }

    static let browsers = [
        Browser(profile: "Library/Application Support/Google/Chrome", bundleID: "com.google.Chrome"),
        Browser(profile: "Library/Application Support/Google/Chrome Beta", bundleID: "com.google.Chrome.beta"),
        Browser(profile: "Library/Application Support/Google/Chrome Dev", bundleID: "com.google.Chrome.dev"),
        Browser(profile: "Library/Application Support/Google/Chrome Canary", bundleID: "com.google.Chrome.canary"),
        Browser(profile: "Library/Application Support/Google/Chrome for Testing", bundleID: "com.google.chrome.for.testing"),
        Browser(profile: "Library/Application Support/Chromium", bundleID: "org.chromium.Chromium"),
        Browser(profile: "Library/Application Support/Arc/User Data", bundleID: "company.thebrowser.Browser"),
        Browser(profile: "Library/Application Support/Dia/User Data", bundleID: "company.thebrowser.dia"),
        Browser(profile: "Library/Application Support/Comet", bundleID: "ai.perplexity.comet"),
        Browser(profile: "Library/Application Support/Microsoft Edge", bundleID: "com.microsoft.edgemac"),
        Browser(profile: "Library/Application Support/Microsoft Edge Beta", bundleID: "com.microsoft.edgemac.Beta"),
        Browser(profile: "Library/Application Support/Microsoft Edge Dev", bundleID: "com.microsoft.edgemac.Dev"),
        Browser(profile: "Library/Application Support/Microsoft Edge Canary", bundleID: "com.microsoft.edgemac.Canary"),
        Browser(profile: "Library/Application Support/BraveSoftware/Brave-Browser", bundleID: "com.brave.Browser"),
        Browser(profile: "Library/Application Support/Vivaldi", bundleID: "com.vivaldi.Vivaldi"),
    ]

    struct RunningApp: Equatable {
        let bundleID: String
        let name: String
    }

    static func browser(named name: String?, running: [RunningApp], windowOrder: [String]) -> Browser? {
        let open = running.filter { app in browsers.contains { $0.bundleID == app.bundleID } }
        let bundleID: String?
        if let name {
            bundleID = open.first { $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.bundleID.caseInsensitiveCompare(name) == .orderedSame }?.bundleID
        } else {
            bundleID = windowOrder.first { owner in open.contains { $0.bundleID == owner } }
        }
        return bundleID.flatMap { id in browsers.first { $0.bundleID == id } }
    }

    static func isBrowser(bundleID: String) -> Bool {
        browsers.contains { $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    @MainActor
    static func onScreenWindows() -> [(bundleID: String, title: String?)] {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.compactMap { window in
            guard window[kCGWindowLayer as String] as? Int == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return nil }
            return (bundleID, window[kCGWindowName as String] as? String)
        }
    }

    static func activePortFile(for browser: Browser, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(browser.profile, isDirectory: true).appendingPathComponent("DevToolsActivePort")
    }

    static let overrideKey = "PERRY_BROWSER_CDP_URL"

    static func activePort(_ contents: String) -> (port: Int, path: String)? {
        let lines = contents.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let port = lines.first.flatMap({ Int($0) }), port > 0 else { return nil }
        return (port, lines.count > 1 ? lines[1] : "")
    }

    static func remoteDebuggingSetting(localState: Data) -> Bool? {
        guard let state = try? JSONValue(parsing: localState) else { return nil }
        return state["devtools"]?["remote_debugging"]?["user-enabled"]?.boolValue
    }

    static func discover(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) async throws -> URL {
        if let override = environment[overrideKey], let url = URL(string: override) {
            if url.scheme == "ws" || url.scheme == "wss" { return url }
            guard let resolved = try await webSocketURL(base: url) else { throw BrowserError.notRunning }
            return resolved
        }
        var debuggingOff = false
        for directory in browsers.map({ home.appendingPathComponent($0.profile, isDirectory: true) }) {
            if let localState = try? Data(contentsOf: directory.appendingPathComponent("Local State")),
               remoteDebuggingSetting(localState: localState) == false {
                debuggingOff = true
            }
            guard let contents = try? String(contentsOf: directory.appendingPathComponent("DevToolsActivePort"), encoding: .utf8),
                  let active = activePort(contents) else { continue }
            do {
                if let url = try await webSocketURL(base: URL(string: "http://127.0.0.1:\(active.port)")!) { return url }
                if !active.path.isEmpty { return URL(string: "ws://127.0.0.1:\(active.port)\(active.path)")! }
            } catch BrowserError.permissionBlocked {
                throw BrowserError.permissionBlocked
            } catch {
                continue
            }
        }
        throw debuggingOff ? BrowserError.remoteDebuggingOff : BrowserError.notRunning
    }

    private static func webSocketURL(base: URL) async throws -> URL? {
        var request = URLRequest(url: base.appendingPathComponent("json/version"))
        request.timeoutInterval = 2
        let (data, response) = try await URLSession.shared.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200:
            return (try? JSONValue(parsing: data))?["webSocketDebuggerUrl"]?.stringValue.flatMap(URL.init(string:))
        case 403:
            throw BrowserError.permissionBlocked
        default:
            return nil
        }
    }
}

actor ChromeDevTools {
    static let shared = ChromeDevTools()

    private let discover: @Sendable () async throws -> URL
    private var socket: URLSessionWebSocketTask?
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var dialogs: [String: JSONValue] = [:]
    private var dragData: [String: JSONValue] = [:]

    init(discover: @escaping @Sendable () async throws -> URL = { try await ChromeEndpoint.discover() }) {
        self.discover = discover
    }

    func send(_ method: String, _ params: [String: JSONValue] = [:], session: String? = nil, timeout: Duration = .seconds(15)) async throws -> JSONValue {
        let socket = try await connected()
        nextID += 1
        let id = nextID
        var message: [String: JSONValue] = ["id": .number(Double(id)), "method": .string(method), "params": .object(params)]
        if let session { message["sessionId"] = .string(session) }
        let text = String(decoding: try JSONEncoder().encode(JSONValue.object(message)), as: UTF8.self)
        let timer = Task { [weak self] in
            try await Task.sleep(for: timeout)
            await self?.fail(id, with: BrowserError.timedOut(method))
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            socket.send(.string(text)) { error in
                guard error != nil else { return }
                Task { await self.fail(id, with: BrowserError.connectionLost) }
            }
        }
    }

    func dialog(session: String) -> JSONValue? {
        dialogs[session]
    }

    func takeDragData(session: String) -> JSONValue? {
        dragData.removeValue(forKey: session)
    }

    private func disconnect() {
        socket?.cancel(with: .goingAway, reason: nil)
        drop()
    }

    private func connected() async throws -> URLSessionWebSocketTask {
        if let socket, socket.state == .running { return socket }
        let url = try await discover()
        let task = URLSession.shared.webSocketTask(with: url)
        task.maximumMessageSize = 64 * 1024 * 1024
        socket = task
        task.resume()
        receive(on: task)
        do {
            _ = try await send("Browser.getVersion", timeout: .seconds(120))
        } catch {
            if socket === task { disconnect() }
            throw error
        }
        return task
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            Task {
                switch result {
                case .success(let message):
                    await self.handle(message)
                    await self.receive(on: task)
                case .failure:
                    await self.closed(task)
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let bytes): data = bytes
        @unknown default: return
        }
        guard let value = try? JSONValue(parsing: data) else { return }
        if let id = value["id"]?.doubleValue.map { Int($0) }, let continuation = pending.removeValue(forKey: id) {
            if let error = value["error"] {
                continuation.resume(throwing: BrowserError.chrome(error["message"]?.stringValue ?? "Chrome refused the request."))
            } else {
                continuation.resume(returning: value["result"] ?? .object([:]))
            }
            return
        }
        guard let method = value["method"]?.stringValue else { return }
        let session = value["sessionId"]?.stringValue
        switch method {
        case "Page.javascriptDialogOpening":
            if let session { dialogs[session] = value["params"] }
        case "Page.javascriptDialogClosed":
            if let session { dialogs.removeValue(forKey: session) }
        case "Input.dragIntercepted":
            if let session { dragData[session] = value["params"]?["data"] }
        case "Target.detachedFromTarget":
            if let detached = value["params"]?["sessionId"]?.stringValue {
                dialogs.removeValue(forKey: detached)
                dragData.removeValue(forKey: detached)
            }
        default:
            break
        }
    }

    private func fail(_ id: Int, with error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func closed(_ task: URLSessionWebSocketTask) {
        guard task === socket else { return }
        drop()
    }

    private func drop() {
        socket = nil
        dialogs.removeAll()
        dragData.removeAll()
        let waiting = pending
        pending.removeAll()
        waiting.values.forEach { $0.resume(throwing: BrowserError.connectionLost) }
    }
}
