import Foundation
import PerryBrain
import PerryGuide

/// `document.read` — pull the text of the frontmost document-bearing window
/// (editors, notes, PDFs) via its accessibility tree. Read-only.
struct DocumentTools {
    let workers: CuaWorkerService
    let lease: ForegroundWorkerLease?
    let observations: AgentObservationStore

    var executors: [any ToolExecutor] {
        [DocumentReadExecutor(workers: workers, lease: lease)]
    }
}

private struct DocumentReadExecutor: ToolExecutor {
    let workers: CuaWorkerService
    let lease: ForegroundWorkerLease?

    private static let maxChars = 20_000
    /// AX role strings that carry document text; AXElement.Role is coarser.
    private static let textRoles: Set<String> = [
        "AXTextArea", "AXWebArea", "AXTextField", "AXStaticText", "AXScrollArea",
    ]

    var spec: ToolSpec {
        ToolSpec(
            name: "document.read",
            description: "Read the text of the frontmost document window (editor, note, PDF, browser page).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bundleID": .object(["type": .string("string")]),
                    "maxChars": .object(["type": .string("integer")]),
                ]),
            ]),
            surfaces: [.talk, .guide, .agent]
        )
    }

    func run(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        let bundleID = call.arguments["bundleID"]?.stringValue
        let maxChars = call.arguments["maxChars"]?.doubleValue.map { min(Int($0), Self.maxChars) } ?? Self.maxChars
        let hint = CuaTargetHint(bundleID: bundleID)
        let resources: Set<BackgroundTaskResource> = bundleID.map { [.application($0.lowercased())] } ?? []

        return try await withCuaWorker(workers, lease: lease, resources: resources) { worker in
            let captured = try await worker.capture(target: hint)
            let elements = captured.accessibilitySnapshotModel?.elements ?? []
            let best = elements
                .filter { Self.textRoles.contains($0.rawRole ?? "") }
                .compactMap { $0.value?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .max(by: { $0.count < $1.count })
            guard var text = best else {
                return .text(
                    call.id,
                    "document.read: no text-bearing element in \(captured.target.title) (\(captured.target.bundleID))",
                    isError: true
                )
            }
            var truncated = false
            if text.count > maxChars {
                text = String(text.prefix(maxChars))
                truncated = true
            }
            var header = "document: \(captured.target.title) (\(captured.target.bundleID))"
            if truncated { header += " — truncated at \(maxChars) chars" }
            return .text(call.id, "\(header)\n\(text)")
        }
    }
}
