import Foundation

/// Declarative spec for the onboarding live demo. The recipe is data — the
/// DemoDirector orchestrates the generic Guide/Do product with it and has no
/// private executor. Version it when the demo changes so old reports stay
/// interpretable.
struct DemoRecipe: Equatable {
    let version: Int
    /// Guide half: what the user is taught, in what context.
    let guideTask: String
    let guideContext: String
    /// Do half: the safe action plus its verifiable end state.
    let workspace: String
    let doAction: String
    let postcondition: String
    let cleanup: String
    let rollback: String
    /// Human-readable result shown on the final onboarding card.
    let expectedResult: String

    var guideGoal: String {
        "show me how to \(guideTask) in \(guideContext)"
    }

    var doGoal: String {
        "In \(workspace), \(doAction); then \(postcondition). \(cleanup) If stopped midway, \(rollback)."
    }

    static let current = DemoRecipe(
        version: 1,
        guideTask: "rename a file",
        guideContext: "the area you circle",
        workspace: "the private PerryDemo workspace",
        doAction: "create a file named Perry demo note.txt",
        postcondition: "move that demo file to Trash",
        cleanup: "Leave nothing else behind.",
        rollback: "delete the demo file so nothing is left behind",
        expectedResult: "Created Perry demo note.txt and moved it to Trash."
    )
}
