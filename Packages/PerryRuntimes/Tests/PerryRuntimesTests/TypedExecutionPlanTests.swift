import Foundation
import XCTest
import PerryCore
@testable import PerryRuntimes

final class TypedExecutionPlanTests: XCTestCase {
    private let workspace = URL(fileURLWithPath: "/private/tmp/perry-plan-fixture", isDirectory: true)

    func testEveryActionFamilyRoundTripsWithExecutableParameters() throws {
        let text = "  e\u{301}\r\n\t🍐\n  "
        let operations: [(ExecutableAction.Operation, ExecutableAction.Postcondition)] = [
            (.transform(workspace: workspace, command: .createUTF8File(path: "report.txt", contents: text)), .fileContents(text)),
            (.transform(workspace: workspace, command: .createDirectory(path: "reports")), .directoryExists),
            (.transform(workspace: workspace, command: .rename(path: "old.txt", destination: "new.txt")), .renamedItem(device: 1, inode: 42)),
            (.transform(workspace: workspace, command: .moveToTrash(path: "discard.txt")), .trashedItem(device: 1, inode: 43)),
            (.computer(
                window: .init(bundleID: "com.apple.TextEdit", processID: 123, windowID: 456, connectionGeneration: 7),
                command: .typeText(text, target: .accessibilityID("editor"))
            ), .elementValue(text)),
            (.integration(accountID: "workspace-one:user-two", command: .slackSendMessage(channelID: "C123", text: text)),
             .integrationResource(identifier: "message-123", expectedText: text)),
            (.shell(
                workspace: workspace,
                executable: .init(path: URL(fileURLWithPath: "/opt/perry/codex"), version: "fixture-1", sha256: String(repeating: "a", count: 64)),
                confinement: .workspaceReadWrite,
                command: .codingTask(runtimeID: "codex", prompt: "Write exactly: \(text)")
            ), .workspaceFileContents(path: "generated.txt", contents: text)),
            (.askUser(prompt: "Which report?", choices: ["Monthly", "Annual"]), .answered),
        ]
        let actions = try operations.enumerated().map { index, pair in
            try ExecutableAction(
                id: ActionID("action-\(index)"), summary: "Fixture \(index)",
                approvalRequirement: .action,
                operation: pair.0, postcondition: pair.1
            )
        }
        let plan = try PerryRuntimes.ExecutionPlan(
            taskID: "original-task", goal: "Preserve every executable field",
            actions: actions, requestedScopes: Set(actions.flatMap { $0.operation.requiredScopes })
        )
        let encoded = try plan.canonicalData()
        let decoded = try JSONDecoder().decode(PerryRuntimes.ExecutionPlan.self, from: encoded)

        XCTAssertEqual(decoded.planID, plan.planID)
        XCTAssertEqual(decoded.actions.map(\.id), plan.actions.map(\.id))
        XCTAssertEqual(try decoded.canonicalData(), encoded)
        XCTAssertEqual(try decoded.approvalDigest(), try plan.approvalDigest())
        guard case .transform(_, .createUTF8File(let path, let contents)) = decoded.actions[0].operation else {
            return XCTFail("File action changed family")
        }
        XCTAssertEqual(path, "report.txt")
        XCTAssertEqual(Array(contents.utf8), Array(text.utf8))
    }

    func testApprovalDigestChangesForByteDistinctContentsAndTargetIdentity() throws {
        let identifier = UUID()
        func plan(text: String, workspace: URL) throws -> PerryRuntimes.ExecutionPlan {
            let action = try ExecutableAction(
                id: "write", summary: "Write", approvalRequirement: .action,
                operation: .transform(workspace: workspace, command: .createUTF8File(path: "report.txt", contents: text)),
                postcondition: .fileContents(text)
            )
            return try PerryRuntimes.ExecutionPlan(
                planID: identifier, taskID: "task", goal: "Write", actions: [action], requestedScopes: [.workspaceWrite]
            )
        }
        let composed = try plan(text: "é", workspace: workspace)
        let decomposed = try plan(text: "e\u{301}", workspace: workspace)
        let retargeted = try plan(text: "é", workspace: workspace.appendingPathComponent("other"))

        XCTAssertNotEqual(try composed.approvalDigest(), try decomposed.approvalDigest())
        XCTAssertNotEqual(try composed.approvalDigest(), try retargeted.approvalDigest())
    }

    func testMalformedPlanAndOperationAreRejectedByDecoder() throws {
        let action = try ExecutableAction(
            id: "question", summary: "Ask", approvalRequirement: .action,
            operation: .askUser(prompt: "Continue?", choices: []), postcondition: .answered
        )
        let plan = try PerryRuntimes.ExecutionPlan(taskID: "task", goal: "Ask", actions: [action], requestedScopes: [])
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: plan.canonicalData()) as? [String: Any])
        for change: ([String: Any]) throws -> [String: Any] in [
            { var value = $0; value["schemaVersion"] = 99; return value },
            { var value = $0; value["taskID"] = ""; return value },
            { var value = $0; value["requestedScopes"] = ["unknown"]; return value },
            { var value = $0; value["actions"] = []; return value },
            { value in
                var value = value
                var actions = try XCTUnwrap(value["actions"] as? [[String: Any]])
                actions[0]["operation"] = ["delegateAutonomously": ["prompt": "anything"]]
                value["actions"] = actions
                return value
            },
        ] {
            let data = try JSONSerialization.data(withJSONObject: change(original))
            XCTAssertThrowsError(try JSONDecoder().decode(PerryRuntimes.ExecutionPlan.self, from: data))
        }
    }

    func testFileActionRejectsTraversalWrongPostconditionAndMissingApproval() throws {
        for path in ["../secret", "/outside", "folder/../secret", "folder//file", ""] {
            XCTAssertThrowsError(try ExecutableAction(
                id: "write", summary: "Write", approvalRequirement: .action,
                operation: .transform(workspace: workspace, command: .createUTF8File(path: path, contents: "value")),
                postcondition: .fileContents("value")
            ))
        }
        XCTAssertThrowsError(try ExecutableAction(
            id: "write", summary: "Write", approvalRequirement: .none,
            operation: .transform(workspace: workspace, command: .createDirectory(path: "folder")),
            postcondition: .directoryExists
        ))
        XCTAssertThrowsError(try ExecutableAction(
            id: "write", summary: "Write", approvalRequirement: .action,
            operation: .transform(workspace: workspace, command: .createUTF8File(path: "file", contents: "é")),
            postcondition: .fileContents("e\u{301}")
        ))
    }

    func testReadWriteShellCannotOmitWorkspaceWriteScope() throws {
        let action = try ExecutableAction(
            id: "shell", summary: "Generate report", approvalRequirement: .action,
            operation: .shell(
                workspace: workspace,
                executable: .init(path: URL(fileURLWithPath: "/opt/perry/codex"), version: "fixture", sha256: String(repeating: "a", count: 64)),
                confinement: .workspaceReadWrite,
                command: .codingTask(runtimeID: "codex", prompt: "Generate report")
            ), postcondition: .workspaceFileContents(path: "report.txt", contents: "report")
        )
        XCTAssertThrowsError(try PerryRuntimes.ExecutionPlan(
            taskID: "task", goal: "Generate report", actions: [action], requestedScopes: [.sandboxedExecution]
        ))
        let plan = try PerryRuntimes.ExecutionPlan(
            taskID: "task", goal: "Generate report", actions: [action],
            requestedScopes: [.sandboxedExecution, .workspaceWrite]
        )
        XCTAssertEqual(plan.requestedScopes, [.sandboxedExecution, .workspaceWrite])
    }

    func testKeyboardAndWindowLevelCommandsKeepTheirTargetSemantics() throws {
        let commands: [ExecutableAction.ComputerCommand] = [
            .hotkey(key: "s", modifiers: [.command, .shift], target: nil),
            .pressKey("return", modifiers: [], target: nil),
            .pressKey("tab", modifiers: [.shift], target: .accessibilityID("editor")),
            .scroll(direction: .down, amount: 3, unit: .page, target: nil),
        ]
        let window = ExecutableAction.WindowIdentity(
            bundleID: "com.apple.TextEdit", processID: 12, windowID: 34, connectionGeneration: 56
        )
        for command in commands {
            let action = try ExecutableAction(
                id: "keyboard", summary: "Operate exact window", approvalRequirement: .action,
                operation: .computer(window: window, command: command),
                postcondition: .visualChange(baselineSHA256: String(repeating: "a", count: 64))
            )
            let decoded = try JSONDecoder().decode(ExecutableAction.self, from: JSONEncoder().encode(action))
            guard case .computer(let decodedWindow, let decodedCommand) = decoded.operation else {
                return XCTFail("Computer operation changed family")
            }
            XCTAssertEqual(decodedWindow, window)
            XCTAssertEqual(decodedCommand, command)
        }
    }

    func testRemainingCommandVariantsRoundTripThroughPlanDecoder() throws {
        let window = ExecutableAction.WindowIdentity(
            bundleID: "com.apple.TextEdit", processID: 12, windowID: 34, connectionGeneration: 56
        )
        let point = ExecutableAction.Selector.windowPixels(x: 12.5, y: 27.25)
        let computerCommands: [ExecutableAction.ComputerCommand] = [
            .click(point), .rightClick(point), .doubleClick(.accessibilityID("document")),
            .drag(from: point, to: .windowPixels(x: 110, y: 220), durationMilliseconds: 250, steps: 12),
        ]
        let integrationCommands: [ExecutableAction.IntegrationCommand] = [
            .notionCreatePage(parentID: "parent", title: "e\u{301}"),
            .notionUpdatePage(pageID: "page", title: "Updated"),
            .notionAppendBlock(blockID: "block", text: "line one\nline two"),
            .linearUpdateIssue(issueID: "issue", title: "Updated"),
        ]
        var actions = try computerCommands.enumerated().map { index, command in
            try ExecutableAction(
                id: ActionID("computer-\(index)"), summary: "Computer action", approvalRequirement: .action,
                operation: .computer(window: window, command: command),
                postcondition: .visualChange(baselineSHA256: String(repeating: "b", count: 64))
            )
        }
        actions += try integrationCommands.enumerated().map { index, command in
            try ExecutableAction(
                id: ActionID("integration-\(index)"), summary: "Integration action", approvalRequirement: .action,
                operation: .integration(accountID: "account", command: command),
                postcondition: .integrationResource(identifier: "resource", expectedText: "Expected")
            )
        }
        actions.append(try ExecutableAction(
            id: "registered-command", summary: "Inspect workspace", approvalRequirement: .action,
            operation: .shell(
                workspace: workspace,
                executable: .init(path: URL(fileURLWithPath: "/opt/perry/tool"), version: "1", sha256: String(repeating: "c", count: 64)),
                confinement: .workspaceReadOnly,
                command: .registeredCommand(arguments: ["--inspect", "a file.txt", ""])
            ),
            postcondition: .workspaceFileContents(path: "report.txt", contents: "Exact\r\n")
        ))
        let plan = try PerryRuntimes.ExecutionPlan(
            taskID: "all-command-variants", goal: "Preserve command parameters", actions: actions,
            requestedScopes: [.computerControl, .integrationWrite, .sandboxedExecution]
        )
        let encoded = try plan.canonicalData()
        let restored = try JSONDecoder().decode(PerryRuntimes.ExecutionPlan.self, from: encoded)
        XCTAssertEqual(restored.actions.count, 9)
        XCTAssertEqual(try restored.canonicalData(), encoded)
    }

    func testUnknownPlanAndActionFieldsAreRejected() throws {
        let action = try ExecutableAction(
            id: "question", summary: "Ask", approvalRequirement: .action,
            operation: .askUser(prompt: "Continue?", choices: []), postcondition: .answered
        )
        let plan = try PerryRuntimes.ExecutionPlan(taskID: "task", goal: "Ask", actions: [action], requestedScopes: [])
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: plan.canonicalData()) as? [String: Any])
        fields["unrecognizedEffect"] = "run a shell command"
        XCTAssertThrowsError(try JSONDecoder().decode(
            PerryRuntimes.ExecutionPlan.self,
            from: JSONSerialization.data(withJSONObject: fields)
        ))
        fields.removeValue(forKey: "unrecognizedEffect")
        var actions = try XCTUnwrap(fields["actions"] as? [[String: Any]])
        actions[0]["unrecognizedEffect"] = "run a shell command"
        fields["actions"] = actions
        XCTAssertThrowsError(try JSONDecoder().decode(
            PerryRuntimes.ExecutionPlan.self,
            from: JSONSerialization.data(withJSONObject: fields)
        ))
        actions[0].removeValue(forKey: "unrecognizedEffect")
        actions[0]["operation"] = ["askUser": ["prompt": "Continue?", "choices": [], "shell": "unexpected"]]
        fields["actions"] = actions
        XCTAssertThrowsError(try JSONDecoder().decode(
            PerryRuntimes.ExecutionPlan.self,
            from: JSONSerialization.data(withJSONObject: fields)
        ))
        actions[0]["operation"] = ["askUser": ["prompt": "Continue?", "choices": []]]
        actions[0]["postcondition"] = ["answered": ["unrecognizedEvidence": true]]
        fields["actions"] = actions
        XCTAssertThrowsError(try JSONDecoder().decode(
            PerryRuntimes.ExecutionPlan.self,
            from: JSONSerialization.data(withJSONObject: fields)
        ))
    }

    func testPolicyFloorsRejectWeakApprovalOnRiskyOperations() throws {
        // Irreversible operations may never run under a whole-plan grant.
        let riskyOperations: [ExecutableAction.Operation] = [
            .transform(workspace: workspace, command: .moveToTrash(path: "old.txt")),
            .integration(accountID: "account", command: .slackSendMessage(channelID: "C1", text: "hi")),
        ]
        for operation in riskyOperations {
            let postcondition: ExecutableAction.Postcondition = switch operation {
            case .transform: .trashedItem(device: 1, inode: 2)
            case .integration: .integrationResource(identifier: "r", expectedText: "hi")
            default: .answered
            }
            XCTAssertThrowsError(try ExecutableAction(
                id: "risky", summary: "Risky", approvalRequirement: .plan,
                operation: operation, postcondition: postcondition
            ), "\(operation.kind.rawValue) accepted plan-scoped approval below its floor")
        }
        // askUser always needs an action-scoped grant — a .plan or .none
        // requirement could not even build its approval.
        for scope in [ApprovalScope.none, .plan] {
            XCTAssertThrowsError(try ExecutableAction(
                id: "question", summary: "Ask", approvalRequirement: scope,
                operation: .askUser(prompt: "Continue?", choices: ["a"]), postcondition: .answered
            ))
        }
        // Reversible operations may run under a plan grant; .action stays valid.
        let window = ExecutableAction.WindowIdentity(
            bundleID: "com.apple.TextEdit", processID: 1, windowID: 2, connectionGeneration: 3
        )
        let reversibleOperations: [ExecutableAction.Operation] = [
            .transform(workspace: workspace, command: .createUTF8File(path: "a.txt", contents: "x")),
            .computer(window: window, command: .click(.windowPixels(x: 1, y: 1))),
        ]
        for operation in reversibleOperations {
            let postcondition: ExecutableAction.Postcondition = switch operation {
            case .transform: .fileContents("x")
            case .computer: .visualChange(baselineSHA256: String(repeating: "a", count: 64))
            default: .answered
            }
            for scope in [ApprovalScope.plan, .action] {
                XCTAssertNoThrow(try ExecutableAction(
                    id: "ok", summary: "OK", approvalRequirement: scope,
                    operation: operation, postcondition: postcondition
                ), "\(operation.kind.rawValue) rejected \(scope) approval")
            }
        }
    }

    func testPolicyTableDerivesTierReversibilityAndClaimsFromOneTable() throws {
        let window = ExecutableAction.WindowIdentity(
            bundleID: "Com.Example.Editor", processID: 1, windowID: 2, connectionGeneration: 3
        )
        let cases: [(ExecutableAction.Operation, TrustTier, ApprovalScope, Bool, Set<ResourceClaim>)] = [
            (.computer(window: window, command: .click(.windowPixels(x: 0, y: 0))), .yellow, .plan, true,
             [.application(bundleID: "com.example.editor")]),
            (.integration(accountID: "acct", command: .linearUpdateIssue(issueID: "i", title: "t")), .orange, .action, false,
             [.integration(accountID: "acct")]),
            (.shell(workspace: workspace, executable: .init(path: URL(fileURLWithPath: "/opt/x"), version: "1", sha256: String(repeating: "a", count: 64)), confinement: .workspaceReadWrite, command: .codingTask(runtimeID: "r", prompt: "p")), .yellow, .plan, true,
             [.workspace(workspace)]),
            (.transform(workspace: workspace, command: .rename(path: "a", destination: "b")), .yellow, .plan, true,
             [.workspace(workspace)]),
            (.transform(workspace: workspace, command: .moveToTrash(path: "a")), .orange, .action, false,
             [.workspace(workspace)]),
            (.askUser(prompt: "p", choices: ["a"]), .green, .action, true, []),
        ]
        for (operation, tier, floor, reversible, claims) in cases {
            XCTAssertEqual(operation.policy.trustTier, tier, operation.kind.rawValue)
            XCTAssertEqual(operation.policy.minimumApproval, floor, operation.kind.rawValue)
            XCTAssertEqual(operation.policy.reversible, reversible, operation.kind.rawValue)
            XCTAssertEqual(operation.policy.claims, claims, operation.kind.rawValue)
        }
    }

    func testPublicationGateRejectsActionsTheSurfaceCannotHonor() throws {
        let window = ExecutableAction.WindowIdentity(
            bundleID: "com.example.Editor", processID: 1, windowID: 2, connectionGeneration: 3
        )
        func makeAction(
            id: String,
            timeout: TimeInterval = 30,
            operation: ExecutableAction.Operation,
            postcondition: ExecutableAction.Postcondition
        ) throws -> ExecutableAction {
            try ExecutableAction(id: ActionID(id), summary: id, timeout: timeout, approvalRequirement: .action, operation: operation, postcondition: postcondition)
        }
        let write = try makeAction(
            id: "write", operation: .transform(workspace: workspace, command: .createUTF8File(path: "a.txt", contents: "x")),
            postcondition: .fileContents("x")
        )
        let click = try makeAction(
            id: "click", operation: .computer(window: window, command: .click(.windowPixels(x: 1, y: 1))),
            postcondition: .visualChange(baselineSHA256: String(repeating: "a", count: 64))
        )
        let slack = try makeAction(
            id: "slack", operation: .integration(accountID: "workspace-one:user-two", command: .slackSendMessage(channelID: "C1", text: "hi")),
            postcondition: .integrationResource(identifier: "m", expectedText: "hi")
        )
        let registered = try makeAction(
            id: "registered", operation: .shell(
                workspace: workspace,
                executable: .init(path: URL(fileURLWithPath: "/opt/x"), version: "1", sha256: String(repeating: "a", count: 64)),
                confinement: .workspaceReadOnly,
                command: .registeredCommand(arguments: ["--inspect"])
            ),
            postcondition: .workspaceFileContents(path: "out.txt", contents: "o")
        )
        let slow = try makeAction(
            id: "slow", timeout: 3600,
            operation: .transform(workspace: workspace, command: .createDirectory(path: "d")),
            postcondition: .directoryExists
        )
        func plan(_ actions: [ExecutableAction]) throws -> PerryRuntimes.ExecutionPlan {
            try PerryRuntimes.ExecutionPlan(
                taskID: "task", goal: "goal", actions: actions,
                requestedScopes: Set(actions.flatMap { $0.operation.requiredScopes })
            )
        }
        let workspaceSurface = ExecutionPlanValidator.Capabilities(supportedOperations: [.transform], workspace: workspace)
        XCTAssertNoThrow(try ExecutionPlanValidator.validate(plan([write]), capabilities: workspaceSurface))
        XCTAssertThrowsError(try ExecutionPlanValidator.validate(plan([click]), capabilities: workspaceSurface), "unsupported operation passed")
        XCTAssertThrowsError(try ExecutionPlanValidator.validate(
            plan([write]), capabilities: .init(supportedOperations: [.transform], workspace: workspace.appendingPathComponent("other"))
        ), "foreign workspace claim passed")
        XCTAssertThrowsError(try ExecutionPlanValidator.validate(
            plan([slack]),
            capabilities: .init(supportedOperations: [.integration], integrationAccounts: ["other-account"])
        ), "unconfigured integration account passed")
        XCTAssertNoThrow(try ExecutionPlanValidator.validate(
            plan([slack]),
            capabilities: .init(supportedOperations: [.integration], integrationAccounts: ["workspace-one:user-two"])
        ))
        XCTAssertThrowsError(try ExecutionPlanValidator.validate(
            plan([registered]),
            capabilities: .init(supportedOperations: Set(ExecutableAction.Operation.Kind.allCases), workspace: workspace)
        ), "registered command reached publication")
        XCTAssertThrowsError(try ExecutionPlanValidator.validate(
            plan([slow]), capabilities: workspaceSurface
        ), "timeout above the surface bound passed")

        let idempotentTrash = try ExecutableAction(
            id: ActionID("trash"),
            summary: "trash",
            approvalRequirement: .action,
            idempotency: .idempotent,
            operation: .transform(workspace: workspace, command: .moveToTrash(path: "old.txt")),
            postcondition: .trashedItem(device: 1, inode: 2)
        )
        XCTAssertThrowsError(try ExecutionPlanValidator.validate(
            plan([idempotentTrash]), capabilities: workspaceSurface
        ), "a non-reversible action declared repeat-safe passed")
        let keyedSlack = try ExecutableAction(
            id: ActionID("keyed-slack"),
            summary: "keyed-slack",
            approvalRequirement: .action,
            idempotency: .keyed("send-1"),
            operation: .integration(accountID: "workspace-one:user-two", command: .slackSendMessage(channelID: "C1", text: "hi")),
            postcondition: .integrationResource(identifier: "m", expectedText: "hi")
        )
        XCTAssertNoThrow(try ExecutionPlanValidator.validate(
            plan([keyedSlack]),
            capabilities: .init(supportedOperations: [.integration], integrationAccounts: ["workspace-one:user-two"])
        ), "keyed dedupe on a non-reversible action was rejected")
    }
}
