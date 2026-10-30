import AppKit
import PerryBrain
import PerryGuide
import PerryRuntimes

@MainActor
enum ToolApprovalPresenter {
    static func present(
        call: ToolCall,
        spec: ToolSpec,
        consentScope: String? = nil,
        consentStore: ToolConsentStore,
        unattended: Bool = false,
        targetFrame: CGRect? = nil
    ) async -> ToolApproval {
        if let consentScope,
           spec.tier < .red,
           await consentStore.isGranted(tool: spec.name, threadID: consentScope) {
            return .approvedOnce
        }
#if DEBUG
        if ProcessInfo.processInfo.environment["PERRY_LAB_AUTO_APPROVE"] == "1", spec.tier < .red {
            AgentTrace.record(.note("approval asked: \(call.name)"))
            return .approvedOnce
        }
#endif
        guard !unattended else { return .denied }
        let target = targetValue(call)
        let card = IntentCard(
            title: headline(call, target: target),
            tier: spec.tier,
            targetSummary: "",
            requiredPhrase: spec.tier >= .red ? (target ?? call.name) : nil,
            approveLabel: "Approve"
        )
        let decision = await IntentCardPresenter.shared.present(
            card: card,
            alwaysAllowLabel: consentScope != nil && spec.tier < .red ? "Always approve" : nil,
            onAlwaysAllow: consentScope.map { scope in
                { Task { try? await consentStore.grantAlways(tool: spec.name, threadID: scope) } }
            }
        )
        switch decision {
        case .run, .stepThrough:
            return spec.tier >= .red ? .approvedTyped : .approvedOnce
        default:
            return .denied
        }
    }

    static func headline(_ call: ToolCall, target: String?) -> String {
        if let headline = UITools.headline(forTool: call.name, target: target) { return headline }
        let file = target.map { URL(fileURLWithPath: $0).lastPathComponent }
        switch call.name {
        case "app.launch": return "Open \(target ?? "this app")?"
        case "files.write": return "Create \(file ?? "a file")?"
        case "files.overwrite": return "Replace \(file ?? "this file")?"
        case "files.move": return "Move \(file ?? "this file")?"
        case "files.trash": return "Move \(file ?? "this file") to the Trash?"
        case "files.mkdir": return file.map { "Create the folder \($0)?" } ?? "Create a folder?"
        case "memory.write": return "Remember this?"
        case "perry.createPerry": return "Make a new helper?"
        case "perry.schedule": return "Schedule this?"
        case "integrations.write": return "Make a change in a connected app?"
        default:
            let parts = call.name.split(separator: ".")
            if parts.first == "mcp", parts.count >= 3 { return "Use \(parts[1])’s \(parts[2...].joined(separator: "."))?" }
            return "Approve this step?"
        }
    }

    private static func targetValue(_ call: ToolCall) -> String? {
        let args = call.arguments.objectValue ?? [:]
        for key in ["label", "name", "bundleID", "path", "key", "direction", "accountID"] {
            if let value = args[key]?.stringValue, !value.isEmpty { return value }
        }
        return nil
    }
}
