import Foundation

@MainActor
enum CompleteErasurePrompt {
    static func makeConfirmation() -> NotchConfirmation {
        NotchConfirmation(
            title: "Erase all Perry data?",
            detail: "I’ll delete tasks, history, memory, approvals, preferences, saved sign-ins and temporary files from this Mac. This can’t be undone.",
            destructiveTitle: "Erase all Perry data",
            cancelTitle: "Cancel"
        )
    }
}
