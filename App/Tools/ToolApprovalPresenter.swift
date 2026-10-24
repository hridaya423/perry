import AppKit
import PerryBrain
import PerryGuide
import PerryRuntimes

/// Presents a tool call for user approval via the intent card near the
/// cursor. Returns true only when the user chose to run it; every other
/// decision (stop/cancel/dismiss) denies. Red-tier calls additionally need
/// the card's typed-confirmation flow — `IntentCardView` enforces the exact
/// displayed phrase, so the card itself is the typed-confirmation surface.
///
/// When a `consentScope` is supplied (thread ID), orange-tier cards offer
/// "Always allow" which records a per-thread grant; future calls of the same
/// tool in that thread skip the card. Red-tier calls are never auto-approved.
/// On `unattended` turns nobody can answer a card — anything without a
/// recorded grant denies immediately rather than parking the job on a window
/// nobody will ever see.
@MainActor
enum ToolApprovalPresenter {
    static func present(
        call: ToolCall,
        spec: ToolSpec,
        consentScope: String? = nil,
        consentStore: ToolConsentStore,
        unattended: Bool = false,
        /// AX-space frame of the element the call acts on, when the last
        /// observation can supply one — anchors the card at the target.
        targetFrame: CGRect? = nil
    ) async -> ToolApproval {
        if let consentScope,
           spec.tier < .red,
           await consentStore.isGranted(tool: spec.name, threadID: consentScope) {
            return .approvedOnce
        }
        guard !unattended else { return .denied }
        let presentation = ToolApprovalPresentation()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return .denied }
            return await withCheckedContinuation { continuation in
                let target = targetValue(call)
                let card = IntentCard(
                    title: headline(call, target: target),
                    tier: spec.tier,
                    targetSummary: "",
                    requiredPhrase: spec.tier >= .red ? (target ?? call.name) : nil,
                    approveLabel: "Allow"
                )
                let window = IntentCardWindow(
                    card: card,
                    allowsStepThrough: false,
                    alwaysAllowLabel: consentScope != nil && spec.tier < .red ? "Always allow" : nil,
                    onAlwaysAllow: consentScope.map { scope in
                        { Task { try? await consentStore.grantAlways(tool: spec.name, threadID: scope) } }
                    }
                ) { decision in
                    presentation.window = nil
                    switch decision {
                    case .run, .stepThrough:
                        continuation.resume(returning: spec.tier >= .red ? .approvedTyped : .approvedOnce)
                    default:
                        continuation.resume(returning: .denied)
                    }
                }
                presentation.window = window
                window.show()
            }
        } onCancel: {
            Task { @MainActor in presentation.window?.cancel() }
        }
    }

    static func headline(_ call: ToolCall, target: String?) -> String {
        let file = target.map { URL(fileURLWithPath: $0).lastPathComponent }
        switch call.name {
        case "app.launch": return "Open \(target ?? "this app")?"
        case "ui.click": return target.map { "Click “\($0)”?" } ?? "Click here?"
        case "ui.doubleclick": return target.map { "Double-click “\($0)”?" } ?? "Double-click here?"
        case "ui.rightclick": return target.map { "Right-click “\($0)”?" } ?? "Right-click here?"
        case "ui.type": return "Type into this field?"
        case "ui.key": return target.map { "Press \($0)?" } ?? "Press a key?"
        case "ui.hotkey": return "Press a keyboard shortcut?"
        case "ui.drag": return "Drag here?"
        case "ui.scroll": return "Scroll this window?"
        case "files.write": return "Create \(file ?? "a file")?"
        case "files.overwrite": return "Replace \(file ?? "this file")?"
        case "files.move": return "Move \(file ?? "this file")?"
        case "files.trash": return "Move \(file ?? "this file") to the Trash?"
        case "files.mkdir": return file.map { "Create the folder \($0)?" } ?? "Create a folder?"
        case "memory.write": return "Remember this?"
        case "perry.createPerry": return "Make a new Perry?"
        case "perry.schedule": return "Schedule this?"
        case "integrations.write": return "Make a change in a connected app?"
        default:
            let parts = call.name.split(separator: ".")
            if parts.first == "mcp", parts.count >= 3 { return "Use \(parts[1])’s \(parts[2...].joined(separator: "."))?" }
            return "Allow \(call.name)?"
        }
    }

    /// Short, non-secret target text — only well-known locator keys, never
    /// raw free-text arguments (those may carry typed content).
    private static func targetValue(_ call: ToolCall) -> String? {
        let args = call.arguments.objectValue ?? [:]
        for key in ["label", "name", "bundleID", "path", "key", "direction", "accountID"] {
            if let value = args[key]?.stringValue, !value.isEmpty { return value }
        }
        return nil
    }
}

@MainActor
private final class ToolApprovalPresentation {
    var window: IntentCardWindow?
}
