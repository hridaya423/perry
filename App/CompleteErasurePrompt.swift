import Foundation

@MainActor
enum CompleteErasurePrompt {
    static func makeConfirmation() -> NotchConfirmation {
        NotchConfirmation(
            title: "Erase all Perry data?",
            detail: "I’ll delete tasks, history, memory, approvals, preferences, saved sign-ins, downloaded brains and voices, temporary files and the ~/PerryDemo folder from this Mac. This can’t be undone.",
            confirmTitle: "Erase all Perry data",
            cancelTitle: "Cancel"
        )
    }
}
