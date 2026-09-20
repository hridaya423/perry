import Foundation
import XCTest
@testable import PerryRuntimes

final class StrictActionDecodingTests: XCTestCase {
    private let workspace = URL(fileURLWithPath: "/private/tmp/perry-strict-plan", isDirectory: true)

    func testStrictOperationMatchesSynthesizedShapeAcrossNestedFamilies() throws {
        let operations: [ExecutableAction.Operation] = [
            .computer(
                window: .init(bundleID: "com.apple.TextEdit", processID: 11, windowID: 22, connectionGeneration: 3),
                command: .hotkey(key: "s", modifiers: [.command, .shift], target: nil)
            ),
            .integration(
                accountID: "slack-account",
                command: .slackSendMessage(channelID: "C123", text: "Keep this exact text")
            ),
            .shell(
                workspace: workspace,
                executable: .init(
                    path: URL(fileURLWithPath: "/opt/perry/codex"),
                    version: "fixture-1",
                    sha256: String(repeating: "a", count: 64)
                ),
                confinement: .workspaceReadWrite,
                command: .codingTask(runtimeID: "codex", prompt: "Inspect the workspace")
            ),
            .transform(
                workspace: workspace,
                command: .createUTF8File(path: "report.txt", contents: "e\u{301}\r\n🍐")
            ),
            .askUser(prompt: "Choose a report", choices: ["Monthly", "Annual"]),
        ]

        for operation in operations {
            let data = try JSONEncoder().encode(OperationEnvelope(operation: operation))
            let decoded = try JSONDecoder().decode(StrictOperationEnvelope.self, from: data).operation
            XCTAssertEqual(decoded, operation)
        }
    }

    func testStrictOperationRejectsUnknownVariantAndNestedFields() throws {
        let unknownVariant = Data(#"{"operation":{"futureOperation":{}}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(StrictOperationEnvelope.self, from: unknownVariant))

        let operation = ExecutableAction.Operation.computer(
            window: .init(bundleID: "com.apple.TextEdit", processID: 11, windowID: 22, connectionGeneration: 3),
            command: .click(.accessibilityID("save"))
        )
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(OperationEnvelope(operation: operation))) as? [String: Any]
        )
        var operationObject = try XCTUnwrap(root["operation"] as? [String: Any])
        var computerObject = try XCTUnwrap(operationObject["computer"] as? [String: Any])
        var windowObject = try XCTUnwrap(computerObject["window"] as? [String: Any])
        windowObject["futureIdentityField"] = true
        computerObject["window"] = windowObject
        operationObject["computer"] = computerObject
        root["operation"] = operationObject

        let data = try JSONSerialization.data(withJSONObject: root)
        XCTAssertThrowsError(try JSONDecoder().decode(StrictOperationEnvelope.self, from: data))
    }

    func testStrictPostconditionRejectsUnknownFieldsAndKeepsEmptyCasesStrict() throws {
        let answered = Data(#"{"postcondition":{"answered":{"future":true}}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(StrictPostconditionEnvelope.self, from: answered))

        let unknown = Data(#"{"postcondition":{"futurePostcondition":{}}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(StrictPostconditionEnvelope.self, from: unknown))

        let valid = Data(#"{"postcondition":{"answered":{}}}"#.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(StrictPostconditionEnvelope.self, from: valid).postcondition,
            .answered
        )
    }
}

private struct OperationEnvelope: Encodable {
    let operation: ExecutableAction.Operation
}

private struct StrictOperationEnvelope: Decodable {
    let operation: ExecutableAction.Operation

    init(from decoder: Decoder) throws {
        let fields = try PlanDecodingFields(decoder, allowed: ["operation"])
        operation = try ExecutableAction.Operation.decodeStrict(from: fields.decoder("operation"))
    }
}

private struct StrictPostconditionEnvelope: Decodable {
    let postcondition: ExecutableAction.Postcondition

    init(from decoder: Decoder) throws {
        let fields = try PlanDecodingFields(decoder, allowed: ["postcondition"])
        postcondition = try ExecutableAction.Postcondition.decodeStrict(from: fields.decoder("postcondition"))
    }
}
