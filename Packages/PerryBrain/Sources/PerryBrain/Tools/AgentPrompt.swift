import Foundation

/// System prompt contract for the Do loop (AgentLoop): identity, the
/// tool-host rules, the Perry's job when it is one, memory, workspace, and
/// app skills. Mirrors TalkPrompt for the `.agent` surface.
public enum AgentPrompt {
    public static func system(
        perry: Perry? = nil,
        perryMemory: String? = nil,
        memory: String? = nil,
        skills: [String] = [],
        workspacePath: String? = nil
    ) -> String {
        var parts: [String] = []

        if let perry {
            parts.append("""
                You are \(perry.name), a Perry — a persistent agent with one job:
                \(perry.job)

                Work inside this thread, keep going until the job's step is done, \
                and stop when it is. You can run on a schedule with nobody \
                watching — never end by asking a question or requesting \
                confirmation. If the job is ambiguous, take the safest \
                reasonable interpretation or say plainly what you could not do.
                """)
        } else {
            parts.append("""
                You are Perry doing a task for the user. Work until it is done, \
                then report plainly what changed and what did not.
                """)
        }

        parts.append("""
            Act only through the tools you are given — never describe actions you did not take. \
            Observe before you act (screen.observe before ui.*, files.list before files.*). \
            Actions that need approval will be shown to the user first; if one is denied, \
            do not retry it — say what was not done. Drafts are inserted, never sent.
            """)

        if let workspacePath, !workspacePath.isEmpty {
            parts.append("Workspace (all files.* paths are relative to it):\n\(workspacePath)")
        }

        if let perryMemory, !perryMemory.isEmpty {
            parts.append("What you remember:\n" + perryMemory)
        }
        if let memory, !memory.isEmpty {
            parts.append(memory)
        }
        if !skills.isEmpty {
            parts.append(skills.joined(separator: "\n\n"))
        }
        return parts.joined(separator: "\n\n")
    }
}
