import AppKit

@MainActor
enum CompleteErasurePrompt {
    static func confirm() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Erase all Perry data?"
        alert.informativeText = "This permanently removes task history, memory, approvals, preferences, provider credentials, OAuth state, temporary media, caches, and Cua artifacts from this Mac. This cannot be undone."
        alert.addButton(withTitle: "Erase all Perry data")
        alert.addButton(withTitle: "Cancel")
        return isConfirmed(alert.runModal())
    }

    static func isConfirmed(_ response: NSApplication.ModalResponse) -> Bool {
        response == .alertFirstButtonReturn
    }
}
