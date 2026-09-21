import Foundation

extension ExecutableAction.Operation {
    static func decodeStrict(from decoder: Decoder) throws -> Self {
        let payload = try PlanDecodingFields.enumPayload(
            decoder,
            cases: [
                "computer": ["window", "command"],
                "integration": ["accountID", "command"],
                "shell": ["workspace", "executable", "confinement", "command"],
                "transform": ["workspace", "command"],
                "askUser": ["prompt", "choices"],
            ]
        )
        switch payload.name {
        case "computer":
            return .computer(
                window: try ExecutableAction.WindowIdentity.decodeStrict(from: payload.fields.decoder("window")),
                command: try ExecutableAction.ComputerCommand.decodeStrict(from: payload.fields.decoder("command"))
            )
        case "integration":
            return .integration(
                accountID: try payload.fields.decode(String.self, "accountID"),
                command: try ExecutableAction.IntegrationCommand.decodeStrict(from: payload.fields.decoder("command"))
            )
        case "shell":
            return .shell(
                workspace: try payload.fields.decode(URL.self, "workspace"),
                executable: try ExecutableAction.ExecutableIdentity.decodeStrict(from: payload.fields.decoder("executable")),
                confinement: try payload.fields.decode(ExecutableAction.SandboxConfinement.self, "confinement"),
                command: try ExecutableAction.SandboxedCommand.decodeStrict(from: payload.fields.decoder("command"))
            )
        case "transform":
            return .transform(
                workspace: try payload.fields.decode(URL.self, "workspace"),
                command: try ExecutableAction.FileTransform.decodeStrict(from: payload.fields.decoder("command"))
            )
        case "askUser":
            return .askUser(
                prompt: try payload.fields.decode(String.self, "prompt"),
                choices: try payload.fields.decode([String].self, "choices")
            )
        default:
            throw ExecutablePlanError.invalid("unknown operation variant")
        }
    }
}

extension ExecutableAction.WindowIdentity {
    static func decodeStrict(from decoder: Decoder) throws -> Self {
        let fields = try PlanDecodingFields(
            decoder,
            allowed: ["bundleID", "processID", "windowID", "connectionGeneration"]
        )
        return Self(
            bundleID: try fields.decode(String.self, "bundleID"),
            processID: try fields.decode(Int32.self, "processID"),
            windowID: try fields.decode(UInt32.self, "windowID"),
            connectionGeneration: try fields.decode(UInt64.self, "connectionGeneration")
        )
    }
}

extension ExecutableAction.Selector {
    static func decodeStrict(from decoder: Decoder) throws -> Self {
        let payload = try PlanDecodingFields.enumPayload(
            decoder,
            cases: [
                "accessibilityID": ["_0"],
                "windowPixels": ["x", "y"],
            ]
        )
        switch payload.name {
        case "accessibilityID":
            return .accessibilityID(try payload.fields.decode(String.self, "_0"))
        case "windowPixels":
            return .windowPixels(
                x: try payload.fields.decode(Double.self, "x"),
                y: try payload.fields.decode(Double.self, "y")
            )
        default:
            throw ExecutablePlanError.invalid("unknown selector variant")
        }
    }
}

extension ExecutableAction.ComputerCommand {
    static func decodeStrict(from decoder: Decoder) throws -> Self {
        let payload = try PlanDecodingFields.enumPayload(
            decoder,
            cases: [
                "click": ["_0"],
                "rightClick": ["_0"],
                "doubleClick": ["_0"],
                "typeText": ["_0", "target"],
                "scroll": ["direction", "amount", "unit", "target"],
                "pressKey": ["_0", "modifiers", "target"],
                "hotkey": ["key", "modifiers", "target"],
                "drag": ["from", "to", "durationMilliseconds", "steps"],
            ]
        )
        switch payload.name {
        case "click":
            return .click(try ExecutableAction.Selector.decodeStrict(from: payload.fields.decoder("_0")))
        case "rightClick":
            return .rightClick(try ExecutableAction.Selector.decodeStrict(from: payload.fields.decoder("_0")))
        case "doubleClick":
            return .doubleClick(try ExecutableAction.Selector.decodeStrict(from: payload.fields.decoder("_0")))
        case "typeText":
            return .typeText(
                try payload.fields.decode(String.self, "_0"),
                target: try ExecutableAction.Selector.decodeStrict(from: payload.fields.decoder("target"))
            )
        case "scroll":
            return .scroll(
                direction: try payload.fields.decode(Direction.self, "direction"),
                amount: try payload.fields.decode(Int.self, "amount"),
                unit: try payload.fields.decode(ScrollUnit.self, "unit"),
                target: try payload.fields.optional(StrictSelectorValue.self, "target")?.value
            )
        case "pressKey":
            return .pressKey(
                try payload.fields.decode(String.self, "_0"),
                modifiers: try payload.fields.decode([KeyModifier].self, "modifiers"),
                target: try payload.fields.optional(StrictSelectorValue.self, "target")?.value
            )
        case "hotkey":
            return .hotkey(
                key: try payload.fields.decode(String.self, "key"),
                modifiers: try payload.fields.decode([KeyModifier].self, "modifiers"),
                target: try payload.fields.optional(StrictSelectorValue.self, "target")?.value
            )
        case "drag":
            return .drag(
                from: try ExecutableAction.Selector.decodeStrict(from: payload.fields.decoder("from")),
                to: try ExecutableAction.Selector.decodeStrict(from: payload.fields.decoder("to")),
                durationMilliseconds: try payload.fields.decode(Int.self, "durationMilliseconds"),
                steps: try payload.fields.decode(Int.self, "steps")
            )
        default:
            throw ExecutablePlanError.invalid("unknown computer command variant")
        }
    }
}

extension ExecutableAction.IntegrationCommand {
    static func decodeStrict(from decoder: Decoder) throws -> Self {
        let payload = try PlanDecodingFields.enumPayload(
            decoder,
            cases: [
                "slackSendMessage": ["channelID", "text"],
                "notionCreatePage": ["parentID", "title"],
                "notionUpdatePage": ["pageID", "title"],
                "notionAppendBlock": ["blockID", "text"],
                "linearUpdateIssue": ["issueID", "title"],
            ]
        )
        switch payload.name {
        case "slackSendMessage":
            return .slackSendMessage(
                channelID: try payload.fields.decode(String.self, "channelID"),
                text: try payload.fields.decode(String.self, "text")
            )
        case "notionCreatePage":
            return .notionCreatePage(
                parentID: try payload.fields.decode(String.self, "parentID"),
                title: try payload.fields.decode(String.self, "title")
            )
        case "notionUpdatePage":
            return .notionUpdatePage(
                pageID: try payload.fields.decode(String.self, "pageID"),
                title: try payload.fields.decode(String.self, "title")
            )
        case "notionAppendBlock":
            return .notionAppendBlock(
                blockID: try payload.fields.decode(String.self, "blockID"),
                text: try payload.fields.decode(String.self, "text")
            )
        case "linearUpdateIssue":
            return .linearUpdateIssue(
                issueID: try payload.fields.decode(String.self, "issueID"),
                title: try payload.fields.decode(String.self, "title")
            )
        default:
            throw ExecutablePlanError.invalid("unknown integration command variant")
        }
    }
}

extension ExecutableAction.ExecutableIdentity {
    static func decodeStrict(from decoder: Decoder) throws -> Self {
        let fields = try PlanDecodingFields(decoder, allowed: ["path", "version", "sha256"])
        return Self(
            path: try fields.decode(URL.self, "path"),
            version: try fields.decode(String.self, "version"),
            sha256: try fields.decode(String.self, "sha256")
        )
    }
}

extension ExecutableAction.SandboxedCommand {
    static func decodeStrict(from decoder: Decoder) throws -> Self {
        let payload = try PlanDecodingFields.enumPayload(
            decoder,
            cases: [
                "registeredCommand": ["arguments"],
                "codingTask": ["runtimeID", "prompt"],
            ]
        )
        switch payload.name {
        case "registeredCommand":
            return .registeredCommand(arguments: try payload.fields.decode([String].self, "arguments"))
        case "codingTask":
            return .codingTask(
                runtimeID: try payload.fields.decode(String.self, "runtimeID"),
                prompt: try payload.fields.decode(String.self, "prompt")
            )
        default:
            throw ExecutablePlanError.invalid("unknown sandboxed command variant")
        }
    }
}

extension ExecutableAction.FileTransform {
    static func decodeStrict(from decoder: Decoder) throws -> Self {
        let payload = try PlanDecodingFields.enumPayload(
            decoder,
            cases: [
                "createUTF8File": ["path", "contents"],
                "createDirectory": ["path"],
                "rename": ["path", "destination"],
                "moveToTrash": ["path"],
                "restoreFromTrash": ["entryName", "destination"],
            ]
        )
        switch payload.name {
        case "createUTF8File":
            return .createUTF8File(
                path: try payload.fields.decode(String.self, "path"),
                contents: try payload.fields.decode(String.self, "contents")
            )
        case "createDirectory":
            return .createDirectory(path: try payload.fields.decode(String.self, "path"))
        case "rename":
            return .rename(
                path: try payload.fields.decode(String.self, "path"),
                destination: try payload.fields.decode(String.self, "destination")
            )
        case "moveToTrash":
            return .moveToTrash(path: try payload.fields.decode(String.self, "path"))
        case "restoreFromTrash":
            return .restoreFromTrash(
                entryName: try payload.fields.decode(String.self, "entryName"),
                destination: try payload.fields.decode(String.self, "destination")
            )
        default:
            throw ExecutablePlanError.invalid("unknown file transform variant")
        }
    }
}

extension ExecutableAction.Postcondition {
    static func decodeStrict(from decoder: Decoder) throws -> Self {
        let payload = try PlanDecodingFields.enumPayload(
            decoder,
            cases: [
                "fileContents": ["_0"],
                "directoryExists": [],
                "renamedItem": ["device", "inode"],
                "trashedItem": ["device", "inode"],
                "elementValue": ["_0"],
                "visualChange": ["baselineSHA256"],
                "integrationResource": ["identifier", "expectedText"],
                "workspaceFileContents": ["path", "contents"],
                "answered": [],
            ]
        )
        switch payload.name {
        case "fileContents":
            return .fileContents(try payload.fields.decode(String.self, "_0"))
        case "directoryExists":
            return .directoryExists
        case "renamedItem":
            return .renamedItem(
                device: try payload.fields.decode(UInt64.self, "device"),
                inode: try payload.fields.decode(UInt64.self, "inode")
            )
        case "trashedItem":
            return .trashedItem(
                device: try payload.fields.decode(UInt64.self, "device"),
                inode: try payload.fields.decode(UInt64.self, "inode")
            )
        case "elementValue":
            return .elementValue(try payload.fields.decode(String.self, "_0"))
        case "visualChange":
            return .visualChange(baselineSHA256: try payload.fields.decode(String.self, "baselineSHA256"))
        case "integrationResource":
            return .integrationResource(
                identifier: try payload.fields.decode(String.self, "identifier"),
                expectedText: try payload.fields.decode(String.self, "expectedText")
            )
        case "workspaceFileContents":
            return .workspaceFileContents(
                path: try payload.fields.decode(String.self, "path"),
                contents: try payload.fields.decode(String.self, "contents")
            )
        case "answered":
            return .answered
        default:
            throw ExecutablePlanError.invalid("unknown postcondition variant")
        }
    }
}

private struct StrictSelectorValue: Decodable {
    let value: ExecutableAction.Selector

    init(from decoder: Decoder) throws {
        value = try ExecutableAction.Selector.decodeStrict(from: decoder)
    }
}
