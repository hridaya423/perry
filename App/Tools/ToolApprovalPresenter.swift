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
@MainActor
enum ToolApprovalPresenter {
    static func present(
        call: ToolCall,
        spec: ToolSpec,
        consentScope: String? = nil,
        consentStore: AgentConsentStore = .shared
    ) async -> Bool {
        if let consentScope,
           spec.tier < .red,
           consentStore.isGranted(scope: consentScope, tool: spec.name) {
            return true
        }
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
                    { consentStore.grant(scope: scope, tool: spec.name) }
                }
            ) { decision in
                continuation.resume(returning: decision == .run || decision == .stepThrough)
            }
            window.showNearCursor()
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
