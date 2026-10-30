import XCTest
@testable import PerryBrain

final class PersonalDetailsTests: XCTestCase {
    private func kinds(_ text: String, known: [String] = []) -> [String: PersonalDetailKind] {
        Dictionary(PersonalDetails.find(in: text, knownNames: known).map { (String(text[$0.range]), $0.kind) }, uniquingKeysWith: { first, _ in first })
    }

    func testFindsEachKind() {
        let text = "Mail ada.lovelace@example.com or call +44 20 7946 0958. Card 4111 1111 1111 1111, IBAN GB82 WEST 1234 5698 7654 32. I live at 221B Baker Street. Key sk-proj-AbCdEf0123456789xyz."
        let found = kinds(text)
        XCTAssertEqual(found["ada.lovelace@example.com"], .email)
        XCTAssertEqual(found["+44 20 7946 0958"], .phone)
        XCTAssertEqual(found["4111 1111 1111 1111"], .card)
        XCTAssertEqual(found["GB82 WEST 1234 5698 7654 32"], .iban)
        XCTAssertEqual(found["221B Baker Street"], .address)
        XCTAssertEqual(found["sk-proj-AbCdEf0123456789xyz"], .secret)
    }

    func testFindsPeopleByNameAndKnownNames() {
        let found = kinds("Tell Sarah Johnson that hridya will join the call.", known: ["Hridya"])
        XCTAssertEqual(found["Sarah Johnson"], .person, "\(found)")
        XCTAssertEqual(found["hridya"], .person)
        XCTAssertEqual(kinds("Sarah called about the venue.")["Sarah"], .person)
    }

    func testLeavesOrdinaryWorkAlone() {
        let text = "Open Figma, export at 2x, then set the meeting for 2026-10-26 at 3:30. Version 1.2.3 fixed order 42 of 1200 items."
        XCTAssertEqual(PersonalDetails.find(in: text), [])
    }

    func testRejectsNumbersThatFailTheirChecksums() {
        XCTAssertTrue(kinds("Card 4111 1111 1111 1112").isEmpty, "\(kinds("Card 4111 1111 1111 1112"))")
        XCTAssertTrue(kinds("Ref GB82 WEST 1234 5698 7654 33").isEmpty, "\(kinds("Ref GB82 WEST 1234 5698 7654 33"))")
    }

    func testRedactionIsConsistentAndRestores() {
        let redactor = Redactor(knownNames: ["Hridya"])
        let first = redactor.redact("Email hridya@example.com about Hridya's trip.")
        let second = redactor.redact("Did Hridya reply from hridya@example.com?")
        XCTAssertEqual(first, "Email ⟨EMAIL_1⟩ about ⟨PERSON_1⟩'s trip.")
        XCTAssertEqual(second, "Did ⟨PERSON_1⟩ reply from ⟨EMAIL_1⟩?")
        XCTAssertEqual(redactor.restore(second), "Did Hridya reply from hridya@example.com?")
        XCTAssertEqual(redactor.hiddenCount, 2)
    }

    func testStreamingRestoreWaitsForAWholePlaceholder() {
        let redactor = Redactor(knownNames: ["Sam"])
        _ = redactor.redact("Ask Sam.")
        var text = RestoringText(redactor: redactor)
        XCTAssertEqual(text.feed("Sure, I will ask ⟨PER"), "Sure, I will ask ")
        XCTAssertEqual(text.feed("SON_1⟩ now"), "Sam now")
        XCTAssertEqual(text.flush(), "")
    }

    func testProviderSeesPlaceholdersAndUserSeesRealValues() async throws {
        let base = ScriptedProvider(responses: [[
            .textDelta("Done. I wrote to ⟨EM"),
            .textDelta("AIL_1⟩ for ⟨PERSON_1⟩."),
            .toolCall(ToolCall(id: "1", name: "mail.send", arguments: .object(["to": .string("⟨EMAIL_1⟩")]))),
            .done(.endTurn)
        ]])
        let provider = RedactingProvider(base: base, vaults: RedactionVaults(knownNames: { ["Hridya"] }))
        XCTAssertFalse(provider.executesTools)
        var text = ""
        var calls: [ToolCall] = []
        let request = ModelRequest(system: "The user is Hridya.", messages: [.user([.text("Email sam@example.com for me")])])
        for try await event in provider.stream(request) {
            if case .textDelta(let chunk) = event { text += chunk }
            if case .toolCall(let call) = event { calls.append(call) }
        }
        let sent = try XCTUnwrap(base.requests.first)
        XCTAssertFalse(sent.system.contains("Hridya"))
        XCTAssertTrue(sent.system.contains("⟨PERSON_1⟩"))
        XCTAssertEqual(sent.messages, [.user([.text("Email ⟨EMAIL_1⟩ for me")])])
        XCTAssertEqual(text, "Done. I wrote to sam@example.com for Hridya.")
        XCTAssertEqual(calls.first?.arguments, .object(["to": .string("sam@example.com")]))
    }
}

final class RedactingToolProviderTests: XCTestCase {
    private final class Native: ModelProvider, @unchecked Sendable {
        let executesTools = true
        let id: ProviderID = "native"
        let displayName = "Native"
        let capabilities: ModelCapabilities = [.tools]
        var sent: [ModelRequest] = []
        var toolOutput: ToolResult?
        func warm() async {}
        func stream(_ request: ModelRequest) -> AsyncThrowingStream<ModelEvent, Error> { AsyncThrowingStream { $0.finish() } }
        func stream(_ request: ModelRequest, executeTool: @escaping ToolExecutionHandler) -> AsyncThrowingStream<ModelEvent, Error> {
            sent.append(request)
            return AsyncThrowingStream { continuation in
                Task {
                    self.toolOutput = try await executeTool(ToolCall(id: "1", name: "contacts.find", arguments: .object(["name": .string("⟨PERSON_1⟩")])))
                    continuation.yield(.done(.endTurn))
                    continuation.finish()
                }
            }
        }
    }

    func testToolsRunOnRealValuesAndResultsLeaveRedacted() async throws {
        let native = Native()
        let tooling = RedactingProvider(base: native, vaults: RedactionVaults(knownNames: { [] }))
        var executed: ToolCall?
        let request = ModelRequest(messages: [.user([.text("Can you find the number for Priya Patel?")])], conversationKey: "thread-1")
        for try await _ in tooling.stream(request, executeTool: { call in
            executed = call
            return .text(call.id, "Priya Patel, priya@example.com")
        }) {}
        XCTAssertEqual(native.sent.first?.messages, [.user([.text("Can you find the number for ⟨PERSON_1⟩?")])])
        XCTAssertEqual(executed?.arguments, .object(["name": .string("Priya Patel")]))
        XCTAssertEqual(native.toolOutput?.content, [.text("⟨PERSON_1⟩, ⟨EMAIL_1⟩")])
    }
}
