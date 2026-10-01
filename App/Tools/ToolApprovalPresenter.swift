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
        unattended: Bool = false
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
                let summary = targetSummary(call)
                let card = IntentCard(
                    title: "Perry wants to run \(spec.name)",
                    detail: spec.description,
                    tier: spec.tier,
                    targetSummary: summary,
                    requiredPhrase: spec.tier >= .red ? summary : nil
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
                window.showNearCursor()
            }
        } onCancel: {
            Task { @MainActor in presentation.window?.cancel() }
        }
    }

    /// Short, non-secret target text for the card — only well-known locator
    /// keys, never raw free-text arguments (those may carry typed content).
    private static func targetSummary(_ call: ToolCall) -> String {
        let args = call.arguments.objectValue ?? [:]
        for key in ["elementID", "label", "bundleID", "path", "direction", "key", "name", "accountID"] {
            if let value = args[key]?.stringValue, !value.isEmpty {
                return "\(call.name): \(value)"
            }
        }
        return call.name
    }
}

@MainActor
private final class ToolApprovalPresentation {
    var window: IntentCardWindow?
}
