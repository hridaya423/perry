import ApplicationServices
import Foundation
import PDFKit
import PerryBrain
import PerryGuide

struct DocumentTools {
    let workers: ScreenWorkerService
    let lease: ForegroundWorkerLease?
    let observations: AgentObservationStore

    var executors: [any ToolExecutor] {
        [DocumentReadExecutor(worker: ToolWorkerContext(workers: workers, lease: lease, observations: observations))]
    }
}

private struct DocumentReadExecutor: ToolExecutor {
    let worker: ToolWorkerContext

    private static let maxChars = 20_000
    private static let textRoles: Set<String> = [
        "AXTextArea", "AXWebArea", "AXTextField", "AXStaticText", "AXScrollArea",
    ]

    var spec: ToolSpec {
        ToolSpec(
            name: "document.read",
            description: "Read the full text of the selected document window (editor, note, PDF, page). screen.observe cuts each value at 200 characters; this returns up to 20,000.",
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
        let observations = worker.observations
        let hint = try observations.prepareCapture(runID: context.runID, bundleID: bundleID)
        let resources: Set<BackgroundTaskResource> = bundleID.map { [.application($0.lowercased())] } ?? []

        return try await worker.withWorker(runID: context.runID, resources: resources) { handle in
            let captured = try await handle.capture(target: hint)
            observations.setTarget(captured.target.hint, runID: context.runID)
            let elements = captured.accessibilitySnapshotModel?.elements ?? []
            let best = elements
                .filter { Self.textRoles.contains($0.rawRole ?? "") }
                .compactMap { captured.elementDetails[$0.stableID]?.value }
                .max(by: { $0.count < $1.count })
            guard var text = best ?? Self.openFileText(of: captured.target) else {
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

    private static func openFileText(of target: ScreenWindowTarget) -> String? {
        let app = AXUIElementCreateApplication(target.processID)
        guard let window = AXQuery.elements(app, kAXWindowsAttribute).first(where: {
            AXQuery.point($0, kAXPositionAttribute).map { abs($0.x - target.x) < 2 && abs($0.y - target.y) < 2 } ?? false
        }),
              let path = AXQuery.string(window, kAXDocumentAttribute), let url = URL(string: path), url.isFileURL,
              url.pathExtension.lowercased() == "pdf", let pdf = PDFDocument(url: url)
        else { return nil }
        let pages = (0..<pdf.pageCount).compactMap { index in
            pdf.page(at: index)?.string.map { "[Page \(index + 1)]\n\($0)" }
        }
        return pages.isEmpty ? nil : pages.joined(separator: "\n\n")
    }
}
