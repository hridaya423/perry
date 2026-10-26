import XCTest
@testable import PerryBrain

final class PromptAssemblerTests: XCTestCase {
    private static let cloud = CapabilitySnapshot.Brain.model(name: "ChatGPT", capabilities: [.vision, .tools, .streaming])
    private static let apple = CapabilitySnapshot.Brain.model(name: "Apple Intelligence", capabilities: [.local, .streaming])

    private static let cases: [(name: String, snapshot: CapabilitySnapshot, user: String?, perry: Perry?)] = [
        ("a-cloud-all-grants-chat", .init(brain: cloud, accessibility: true, screenRecording: true, connectedApps: ["Notion", "Gmail"], mode: .chat), nil, nil),
        ("b-apple-only-chat", .init(brain: apple, accessibility: true, screenRecording: true, connectedApps: [], mode: .chat), nil, nil),
        ("d-cloud-no-accessibility-talk", .init(brain: cloud, accessibility: false, screenRecording: true, connectedApps: [], mode: .talk), nil, nil),
        ("e-cloud-no-screen-recording-do", .init(brain: cloud, accessibility: true, screenRecording: false, connectedApps: [], mode: .doTask), nil, nil),
        ("f-cloud-memory-chat", .init(brain: cloud, accessibility: true, screenRecording: true, connectedApps: [], mode: .chat), "Name: Hridya. Prefers short answers.", nil),
        ("g-perry-job", .init(brain: cloud, accessibility: true, screenRecording: true, connectedApps: ["Gmail"], mode: .perryJob), nil,
         Perry(name: "Inbox Keeper", job: "Archive newsletters every morning.", threadID: "t1")),
        ("h-cloud-guide", .init(brain: cloud, accessibility: true, screenRecording: true, connectedApps: [], mode: .guide), nil, nil),
    ]

    func testTalkModeKeepsTheDrawingSyntaxAndNeverActs() {
        let prompt = assemble(Self.cases[2])
        XCTAssertTrue(prompt.contains("⟦verb e1 \"label\"⟧"))
        XCTAssertTrue(prompt.contains("you never act"))
    }

    func testPerryJobCarriesItsJobAndMemory() {
        let perry = Perry(name: "Inbox Keeper", job: "keep my inbox clean", threadID: "t1")
        let snapshot = CapabilitySnapshot(brain: Self.cloud, accessibility: true, screenRecording: true, connectedApps: [], mode: .perryJob)
        let prompt = PromptAssembler.assemble(snapshot, about: nil, perry: perry, perryMemory: "archive newsletters", skills: ["In Mail, the archive button is top-left."], workspacePath: "  ")
        XCTAssertTrue(prompt.contains("Inbox Keeper"))
        XCTAssertTrue(prompt.contains("keep my inbox clean"))
        XCTAssertTrue(prompt.contains("archive newsletters"))
        XCTAssertTrue(prompt.contains("archive button"))
        XCTAssertFalse(prompt.contains("workspace folder (file paths"))
    }

    private func assemble(_ entry: (name: String, snapshot: CapabilitySnapshot, user: String?, perry: Perry?)) -> String {
        PromptAssembler.assemble(entry.snapshot, about: entry.user, perry: entry.perry, perryMemory: nil, skills: [], workspacePath: "~/Perry")
    }

    func testNoToolsBrainIsNeverToldToUseTools() {
        let prompt = assemble(Self.cases[1])
        XCTAssertFalse(prompt.contains("screen.observe"))
        XCTAssertFalse(prompt.contains("Observe before you act"))
        XCTAssertFalse(prompt.lowercased().contains("files."))
    }

    func testIdentityStaysShort() {
        XCTAssertLessThanOrEqual(PromptAssembler.identity.split(whereSeparator: \.isWhitespace).count, 250)
    }

    func testEveryBlockedCapabilityHasAFix() {
        for entry in Self.cases {
            for capability in CapabilityResolver.resolve(entry.snapshot) {
                if case .blocked(let reason, let fix) = capability.status {
                    XCTAssertFalse(reason.isEmpty, entry.name)
                    XCTAssertFalse(fix.isEmpty, entry.name)
                }
            }
        }
        for capability in CapabilityResolver.resolve(.init(brain: .none, accessibility: false, screenRecording: false, connectedApps: [], mode: .chat)) {
            XCTAssertNotEqual(capability.status, .available)
        }
    }

    func testCannotAlwaysCarriesItsFix() {
        for entry in Self.cases {
            for line in assemble(entry).split(separator: "\n") where line.lowercased().contains("cannot") || line.lowercased().contains("can't") {
                XCTAssertTrue(line.contains("Fix:") || line.contains("Settings"), "\(entry.name): \(line)")
            }
        }
    }

    func testCapabilityBlockNamesNoTools() {
        for entry in Self.cases {
            let block = PromptAssembler.capabilityBlock(entry.snapshot)
            XCTAssertNil(block.range(of: #"\b(screen|ui|files|integrations|memory|draw)\.[a-z]"#, options: .regularExpression), entry.name)
        }
    }

    func testAssemblyIsDeterministicAndSorted() {
        for entry in Self.cases {
            XCTAssertEqual(assemble(entry), assemble(entry), entry.name)
        }
        XCTAssertTrue(assemble(Self.cases[0]).contains("Gmail, Notion"))
    }

    func testOnDevicePromptFitsItsBudget() {
        XCTAssertLessThan(assemble(Self.cases[1]).utf8.count / 4, 700)
    }

    func testCapabilityQuestionsAreRecognisedAndOthersAreNot() {
        let questions = [
            "what can you do", "What can you do?", "what can you help me with", "What can you help with?",
            "how can you help", "How can you help me?", "what do you do", "what are you able to do",
            "what are your capabilities", "what can I ask you", "Perry, what can you do?", "hey perry what can you do",
            "what can you do right now", "what can you do here", "what can you do for me", "what are you capable of",
            "what are you good at", "what can Perry do", "help", "Help!",
        ]
        let others = [
            "", "help me write a poem", "help me rename these files", "what can you do with this spreadsheet",
            "what can you see on my screen", "how do I export a PDF", "show me how to share", "do this for me: tidy Downloads",
            "what is this button", "can you help me write an email", "what does this error mean", "what can I do about this error",
            "who made you", "stop", "what time is it", "summarise this page", "helpful tips for Keynote",
            "what did you do", "what can you do to fix this", "explain this chart",
        ]
        for text in questions { XCTAssertTrue(PromptAssembler.isCapabilityQuestion(text), text) }
        for text in others { XCTAssertFalse(PromptAssembler.isCapabilityQuestion(text), text) }
    }

    func testCapabilityAnswerFollowsTheSnapshot() {
        let all = PromptAssembler.answerForCapabilityQuestion(Self.cases[0].snapshot)
        XCTAssertTrue(all.contains("see your screen"))
        XCTAssertTrue(all.contains("do this for me"))
        XCTAssertTrue(all.contains("Gmail, Notion"))
        XCTAssertFalse(all.contains("Settings"))

        let apple = PromptAssembler.answerForCapabilityQuestion(Self.cases[1].snapshot)
        XCTAssertTrue(apple.contains("privately on your Mac with Apple Intelligence"))
        XCTAssertFalse(apple.contains("I can see your screen"))
        XCTAssertTrue(apple.contains("read the window"))
        XCTAssertTrue(apple.contains("Settings > Brain"))

        let noScreen = PromptAssembler.answerForCapabilityQuestion(Self.cases[2].snapshot)
        XCTAssertTrue(noScreen.contains("Accessibility"))
        XCTAssertFalse(noScreen.contains("do this for me"))

        let none = PromptAssembler.answerForCapabilityQuestion(.init(brain: .none, accessibility: true, screenRecording: true, connectedApps: [], mode: .chat))
        XCTAssertEqual(none, PromptAssembler.noBrainAnswer)
        XCTAssertTrue(none.contains("Settings"))

        for entry in Self.cases {
            let answer = PromptAssembler.answerForCapabilityQuestion(entry.snapshot)
            XCTAssertLessThanOrEqual(answer.split(separator: ".").count, 5, entry.name)
            XCTAssertNil(answer.range(of: #"\b(screen|ui|files|integrations)\.[a-z]"#, options: .regularExpression), entry.name)
        }
    }

    func testGoldens() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/PromptGoldens")
        let update = ProcessInfo.processInfo.environment["UPDATE_GOLDENS"] == "1"
        for entry in Self.cases {
            let url = directory.appendingPathComponent(entry.name + ".txt")
            let actual = assemble(entry)
            if update {
                try actual.write(to: url, atomically: true, encoding: .utf8)
                continue
            }
            let expected = try String(contentsOf: url, encoding: .utf8)
            XCTAssertEqual(actual, expected, "\(entry.name) changed. Review it, then rerun with UPDATE_GOLDENS=1.")
        }
    }
}
