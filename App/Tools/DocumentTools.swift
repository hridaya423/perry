import ApplicationServices
import Foundation
import PDFKit
import PerryBrain
import PerryGuide

/// `document.read` — pull the text of the frontmost document-bearing window
/// (editors, notes, PDFs) via its accessibility tree. Read-only.
struct DocumentTools {
    let workers: CuaWorkerService
    let lease: ForegroundWorkerLease?
    let observations: AgentObservationStore

    var executors: [any ToolExecutor] {
        [DocumentReadExecutor(workers: workers, lease: lease, observations: observations)]
    }
}

private struct DocumentReadExecutor: ToolExecutor {
    let workers: CuaWorkerService
    let lease: ForegroundWorkerLease?
    let observations: AgentObservationStore

    private static let maxChars = 20_000
    /// AX role strings that carry document text; AXElement.Role is coarser.
    private static let textRoles: Set<String> = [
        "AXTextArea", "AXWebArea", "AXTextField", "AXStaticText", "AXScrollArea",
    ]

    var spec: ToolSpec {
        ToolSpec(
            name: "document.read",
            description: "Read the text of the selected document window (editor, note, PDF, browser page).",
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
        let hint = try observations.prepareCapture(runID: context.runID, bundleID: bundleID)
        let resources: Set<BackgroundTaskResource> = bundleID.map { [.application($0.lowercased())] } ?? []

        return try await withCuaWorker(workers, lease: lease, runID: context.runID, resources: resources) { worker in
            let captured = try await worker.capture(target: hint)
            observations.setTarget(captured.target.hint, runID: context.runID)
            let elements = captured.accessibilitySnapshotModel?.elements ?? []
            let best = elements
                .filter { Self.textRoles.contains($0.rawRole ?? "") }
                .compactMap { $0.value?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
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

    private static func openFileText(of target: CuaWindowTarget) -> String? {
        let app = AXUIElementCreateApplication(target.processID)
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
              let windows = windows as? [AXUIElement],
              let window = windows.first(where: { frame(of: $0).map { abs($0.minX - target.x) < 2 && abs($0.minY - target.y) < 2 } ?? false })
        else { return nil }
        var document: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &document) == .success,
              let path = document as? String, let url = URL(string: path), url.isFileURL,
              url.pathExtension.lowercased() == "pdf", let pdf = PDFDocument(url: url)
        else { return nil }
        let pages = (0..<pdf.pageCount).compactMap { index in
            pdf.page(at: index)?.string.map { "[Page \(index + 1)]\n\($0)" }
        }
        return pages.isEmpty ? nil : pages.joined(separator: "\n\n")
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
              let position, CFGetTypeID(position) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin) else { return nil }
        return CGRect(origin: origin, size: .zero)
    }
}
