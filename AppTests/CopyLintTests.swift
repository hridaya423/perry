import XCTest

final class CopyLintTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private static let scope = [
        "App/Onboarding", "App/Notch", "App/Home", "App/Permissions", "App/Shortcuts", "App/Settings", "App/Brain", "App/Talk",
        "App/AgentActivityStrip.swift", "App/IntentCardView.swift", "App/IntentCardPresenter.swift", "App/FailureNotice.swift",
        "App/ExecutionFinalizer.swift", "App/RoutineRunCopy.swift", "App/RoutineOffer.swift", "App/GuideSessionCoordinator.swift",
        "App/GuideControlsWindow.swift", "App/StatusMenuController.swift", "App/HotkeyController.swift", "App/DictationController.swift",
        "App/VoiceController.swift", "App/Voice/DictationInsertion.swift", "App/BackgroundTaskRecoveryNotice.swift",
        "App/CompactConversationView.swift", "App/Tools/ToolApprovalPresenter.swift", "App/Tools/AgentCoordinator.swift",
    ]

    private static let retired = [
        "Trust tier", "Read-back", "Cua", "agent runner", "Perrys", "Settings ›", "Settings →", "Watch & Learn",
        "Don’t allow", "Awaiting approval", "Approval needed", "Check needed", "Looks right", "Settings > Models",
    ]

    private struct Hit: CustomStringConvertible {
        let file: String
        let line: Int
        let reason: String
        let text: String
        var description: String { "\(file):\(line) \(reason): \(text)" }
    }

    private static func swiftFiles() -> [URL] {
        scope.flatMap { path -> [URL] in
            let url = root.appendingPathComponent(path)
            guard url.hasDirectoryPath || url.pathExtension.isEmpty else { return [url] }
            let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
            return (walker?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
        }
    }

    private static func literals(in line: String) -> [String] {
        let chars = Array(line)
        var found: [String] = []
        var i = 0
        while i < chars.count {
            guard chars[i] == "\"" else { i += 1; continue }
            var text = ""
            i += 1
            while i < chars.count, chars[i] != "\"" {
                if chars[i] == "\\", i + 1 < chars.count {
                    if chars[i + 1] == "(" {
                        var depth = 0
                        i += 1
                        repeat {
                            if chars[i] == "(" { depth += 1 } else if chars[i] == ")" { depth -= 1 }
                            i += 1
                        } while depth > 0 && i < chars.count
                        text.append("§")
                    } else {
                        text.append(chars[i + 1])
                        i += 2
                    }
                } else {
                    text.append(chars[i])
                    i += 1
                }
            }
            found.append(text)
            i += 1
        }
        return found
    }

    private static func hits() throws -> [Hit] {
        var hits: [Hit] = []
        let apostrophe = try NSRegularExpression(pattern: "[A-Za-z]'[A-Za-z]")
        let voice = try NSRegularExpression(pattern: "\\b(could not|cannot|will not)\\b", options: .caseInsensitive)
        let button = try NSRegularExpression(pattern: "(?:Button\\(|NotchDialog\\.Action\\(|OnboardingPrimaryLabel\\(title: )\"([^\"]+)\"")
        for file in swiftFiles() {
            let name = file.path.replacingOccurrences(of: root.path + "/", with: "")
            let source = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in source.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !trimmed.contains("\"\"\"") else { continue }
                func add(_ reason: String, _ text: String) { hits.append(Hit(file: name, line: index + 1, reason: reason, text: text)) }
                for text in literals(in: line) {
                    let range = NSRange(text.startIndex..., in: text)
                    if let term = retired.first(where: text.contains) { add("retired term \(term)", text) }
                    if apostrophe.firstMatch(in: text, range: range) != nil { add("straight apostrophe", text) }
                    if voice.firstMatch(in: text, range: range) != nil { add("stiff negation", text) }
                    if text == "Allow" { add("Allow as a button title", text) }
                }
                let whole = NSRange(line.startIndex..., in: line)
                for match in button.matches(in: line, range: whole) {
                    guard let titleRange = Range(match.range(at: 1), in: line) else { continue }
                    let title = literals(in: "\"\(line[titleRange])\"").first ?? ""
                    if title.split(separator: " ").count > 3 { add("button title over three words", title) }
                }
            }
        }
        return hits
    }

    func testInterfaceCopyFollowsTheGlossary() throws {
        let hits = try Self.hits()
        XCTAssertTrue(hits.isEmpty, "\n" + hits.map(\.description).joined(separator: "\n"))
    }
}
