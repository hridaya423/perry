import Foundation

@MainActor
enum CompleteErasurePrompt {
    static func makeConfirmation() -> NotchConfirmation {
        NotchConfirmation(
            title: "Erase all Perry data?",
            detail: "This permanently removes task history, memory, approvals, preferences, provider credentials, OAuth state, temporary media, caches, and Cua artifacts from this Mac. This cannot be undone.",
            destructiveTitle: "Erase all Perry data",
            cancelTitle: "Cancel"
        )
    }
}
