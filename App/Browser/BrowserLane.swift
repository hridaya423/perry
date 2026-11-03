import AppKit
import Foundation
import PerryBrain
import PerryCore

actor BrowserLane {
    static let shared = BrowserLane(devTools: .shared)

    struct Tab: Sendable, Equatable {
        let id: String
        let title: String
        let url: String
    }

    private struct Attachment {
        let target: String
        let session: String
    }

    private static let internalSchemes = ["chrome://", "chrome-untrusted://", "devtools://", "chrome-extension://", "edge://", "brave://", "about:"]

    let devTools: ChromeDevTools
    private var attachments: [UUID: Attachment] = [:]

    init(devTools: ChromeDevTools) {
        self.devTools = devTools
    }

    func tabs() async throws -> [Tab] {
        try await devTools.send("Target.getTargets")["targetInfos"]?.arrayValue?.compactMap { info -> Tab? in
            guard info["type"]?.stringValue == "page", let id = info["targetId"]?.stringValue else { return nil }
            return Tab(id: id, title: info["title"]?.stringValue ?? "", url: info["url"]?.stringValue ?? "")
        } ?? []
    }

    func currentTab(run: UUID) async throws -> Tab {
        let target = try await attachment(run: run).target
        let info = try await devTools.send("Target.getTargetInfo", ["targetId": .string(target)])["targetInfo"]
        return Tab(id: target, title: info?["title"]?.stringValue ?? "", url: info?["url"]?.stringValue ?? "")
    }

    func command(_ method: String, _ params: [String: JSONValue] = [:], run: UUID, timeout: Duration = .seconds(15)) async throws -> JSONValue {
        let session = try await attachment(run: run).session
        do {
            return try await devTools.send(method, params, session: session, timeout: timeout)
        } catch BrowserError.chrome(let message) where message.localizedCaseInsensitiveContains("session") {
            attachments.removeValue(forKey: run)
            return try await devTools.send(method, params, session: try await attachment(run: run).session, timeout: timeout)
        }
    }

    func session(run: UUID) async throws -> String {
        try await attachment(run: run).session
    }

    func dialog(run: UUID) async throws -> JSONValue? {
        await devTools.dialog(session: try await attachment(run: run).session)
    }

    @discardableResult
    func attach(run: UUID, to target: String) async throws -> Tab {
        let tab = try await tabs().first { $0.id == target } ?? Tab(id: target, title: "", url: "")
        try Self.ensureAllowed(tab)
        let session = try await devTools.send("Target.attachToTarget", ["targetId": .string(target), "flatten": .bool(true)])["sessionId"]?.stringValue
        guard let session else { throw BrowserError.chrome("Chrome didn’t attach to that tab.") }
        _ = try await devTools.send("Page.enable", session: session)
        if let previous = attachments[run], previous.session != session {
            _ = try? await devTools.send("Target.detachFromTarget", ["sessionId": .string(previous.session)])
        }
        attachments[run] = Attachment(target: target, session: session)
        return tab
    }

    func release(run: UUID) async {
        guard let previous = attachments.removeValue(forKey: run) else { return }
        _ = try? await devTools.send("Target.detachFromTarget", ["sessionId": .string(previous.session)])
    }

    func resolve(_ reference: String) async throws -> Tab {
        let all = try await tabs()
        if let exact = all.first(where: { $0.id == reference }) {
            try Self.ensureAllowed(exact)
            return exact
        }
        let matches = all.filter { $0.id.hasPrefix(reference) || $0.url.contains(reference) || $0.title.localizedCaseInsensitiveContains(reference) }
        guard let tab = matches.first else { throw BrowserError.chrome("No tab matches “\(reference)”.") }
        try Self.ensureAllowed(tab)
        return tab
    }

    private func attachment(run: UUID) async throws -> Attachment {
        if let existing = attachments[run] {
            let info = try? await devTools.send("Target.getTargetInfo", ["targetId": .string(existing.target)])["targetInfo"]
            if let info {
                try Self.ensureAllowed(Tab(id: existing.target, title: info["title"]?.stringValue ?? "", url: info["url"]?.stringValue ?? ""))
                return existing
            }
            attachments.removeValue(forKey: run)
        }
        let pages = try await tabs().filter { !Self.isInternal($0.url) }
        let front = await MainActor.run { ChromeEndpoint.onScreenWindows().first { ChromeEndpoint.isBrowser(bundleID: $0.bundleID) }?.title }
        let chosen = front.flatMap { title in pages.first { !$0.title.isEmpty && title.hasPrefix($0.title) } } ?? pages.first
        guard let chosen else { throw BrowserError.noTab }
        try await attach(run: run, to: chosen.id)
        return attachments[run]!
    }

    static func isInternal(_ url: String) -> Bool {
        internalSchemes.contains { url.hasPrefix($0) }
    }

    static func isProtected(_ tab: Tab) -> Bool {
        TrustGuard().isWindowBlocked(WindowContext(appBundleID: "", title: tab.title))
    }

    static func ensureAllowed(_ tab: Tab) throws {
        if isProtected(tab) { throw BrowserError.protectedPage }
    }
}

enum BrowserKeys {
    struct Stroke: Equatable {
        let key: String
        let code: String
        let virtualKey: Int
        let text: String
        let modifiers: Int
    }

    private static let named: [String: (Int, String, String)] = [
        "enter": (13, "Enter", "\r"), "return": (13, "Enter", "\r"), "tab": (9, "Tab", "\t"),
        "backspace": (8, "Backspace", ""), "delete": (46, "Delete", ""), "escape": (27, "Escape", ""), "esc": (27, "Escape", ""),
        "space": (32, "Space", " "), "arrowleft": (37, "ArrowLeft", ""), "left": (37, "ArrowLeft", ""),
        "arrowup": (38, "ArrowUp", ""), "up": (38, "ArrowUp", ""), "arrowright": (39, "ArrowRight", ""), "right": (39, "ArrowRight", ""),
        "arrowdown": (40, "ArrowDown", ""), "down": (40, "ArrowDown", ""), "home": (36, "Home", ""), "end": (35, "End", ""),
        "pageup": (33, "PageUp", ""), "pagedown": (34, "PageDown", ""),
    ]
    private static let punctuation: [Character: (String, Int)] = [
        "`": ("Backquote", 192), "-": ("Minus", 189), "=": ("Equal", 187), "[": ("BracketLeft", 219), "]": ("BracketRight", 221),
        "\\": ("Backslash", 220), ";": ("Semicolon", 186), "'": ("Quote", 222), ",": ("Comma", 188), ".": ("Period", 190), "/": ("Slash", 191),
    ]
    private static let shifted: [Character: Character] = [
        "~": "`", "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/",
    ]
    private static let modifierBits: [String: Int] = ["alt": 1, "option": 1, "ctrl": 2, "control": 2, "cmd": 4, "command": 4, "meta": 4, "shift": 8]

    static func modifiers(_ names: [String]) -> Int {
        names.reduce(0) { $0 | (modifierBits[$1.lowercased()] ?? 0) }
    }

    static func stroke(_ key: String, modifiers: Int = 0) -> Stroke {
        if let entry = named[key.lowercased()] {
            return Stroke(key: entry.1 == "Space" ? " " : entry.1, code: entry.1, virtualKey: entry.0, text: entry.2, modifiers: modifiers)
        }
        guard key.count == 1, let character = key.first else {
            return Stroke(key: key, code: key, virtualKey: 0, text: "", modifiers: modifiers)
        }
        let base = shifted[character] ?? character
        let needsShift = shifted[character] != nil || character.isUppercase
        let shortcut = modifiers & 7 != 0
        let effective = needsShift && !shortcut ? modifiers | 8 : modifiers
        if base.isASCII, base.isLetter {
            let upper = String(base).uppercased()
            return Stroke(key: key, code: "Key\(upper)", virtualKey: Int(upper.unicodeScalars.first!.value), text: key, modifiers: effective)
        }
        if base.isASCII, base.isNumber {
            return Stroke(key: key, code: "Digit\(base)", virtualKey: Int(base.unicodeScalars.first!.value), text: key, modifiers: effective)
        }
        if let entry = punctuation[base] {
            return Stroke(key: key, code: entry.0, virtualKey: entry.1, text: key, modifiers: effective)
        }
        return Stroke(key: key, code: "", virtualKey: 0, text: key, modifiers: modifiers)
    }

    static func events(for stroke: Stroke) -> [[String: JSONValue]] {
        var base: [String: JSONValue] = [
            "key": .string(stroke.key), "code": .string(stroke.code), "modifiers": .number(Double(stroke.modifiers)),
            "windowsVirtualKeyCode": .number(Double(stroke.virtualKey)), "nativeVirtualKeyCode": .number(Double(stroke.virtualKey)),
        ]
        let shortcut = stroke.modifiers & 7 != 0
        let printable = stroke.key.count == 1 && !stroke.text.isEmpty && !shortcut
        if shortcut, stroke.code.hasPrefix("Key") {
            let command: String? = ["KeyA": "SelectAll", "KeyC": "Copy", "KeyV": "Paste", "KeyX": "Cut", "KeyZ": "Undo"][stroke.code]
            if let command, stroke.modifiers & 4 != 0 { base["commands"] = .array([.string(command)]) }
        }
        var down = base
        down["type"] = .string(base["commands"] == nil ? "keyDown" : "rawKeyDown")
        if !printable, !stroke.text.isEmpty, !shortcut { down["text"] = .string(stroke.text) }
        var events = [down]
        if printable {
            var char = base
            char["type"] = .string("char")
            char["text"] = .string(stroke.text)
            events.append(char)
        }
        var up = base
        up["type"] = .string("keyUp")
        up.removeValue(forKey: "commands")
        events.append(up)
        return events
    }
}
