import Foundation
import PerryBrain
import PerryGuide

/// `browser.read` — observe a browser window and surface its address-bar URL
/// alongside the element index. Read-only; safe on every surface.
struct BrowserTools {
    let workers: CuaWorkerService
    let lease: ForegroundWorkerLease?
    let observations: AgentObservationStore

    var executors: [any ToolExecutor] {
        [BrowserReadExecutor(workers: workers, lease: lease, observations: observations)]
    }

    /// Browsers Perry knows how to find for a bare `browser.read`.
    static let knownBrowserBundleIDs = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser", // Arc
        "com.brave.Browser",
        "org.mozilla.firefox",
    ]
}

private struct BrowserReadExecutor: ToolExecutor {
    let workers: CuaWorkerService
    let lease: ForegroundWorkerLease?
    let observations: AgentObservationStore

    var spec: ToolSpec {
        ToolSpec(
            name: "browser.read",
            description: "Read the selected browser window: URL, title, and its elements (compact ids for other tools).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bundleID": .object(["type": .string("string"), "description": .string("Browser to read; defaults to this run’s selected window")]),
                ]),
            ]),
            surfaces: [.talk, .guide, .agent]
        )
    }

    func run(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        let bundleID = call.arguments["bundleID"]?.stringValue
        let hint = try observations.prepareCapture(runID: context.runID, bundleID: bundleID)
        let resources: Set<BackgroundTaskResource> = bundleID.map { [.application($0.lowercased())] } ?? []

        return try await withCuaWorker(workers, lease: lease, runID: context.runID, resources: resources) { worker in
            let captured = try await worker.capture(target: hint)
            guard BrowserTools.knownBrowserBundleIDs.contains(captured.target.bundleID) || bundleID != nil else {
                return .text(
                    call.id,
                    "selected window belongs to \(captured.target.bundleID). Specify a browser application to read.",
                    isError: true
                )
            }
            let snapshot = captured.accessibilitySnapshotModel
            let elements = (snapshot?.elements ?? [])
                .filter { $0.sensitivity != .secure }
                .map { element in
                    ObservedElement(
                        id: element.stableID,
                        role: element.rawRole ?? "AX\(element.role.rawValue)",
                        label: element.label ?? "",
                        frame: CGRect(
                            x: element.frame.x, y: element.frame.y,
                            width: element.frame.width, height: element.frame.height
                        ),
                        windowID: Int(captured.target.windowID)
                    )
                }
            let index = ElementIndex(elements: elements, prefix: observations.nextIDPrefix(runID: context.runID))
            observations.store(
                AgentObservationStore.Snapshot(
                    index: index,
                    window: captured.target,
                    screenshotData: captured.screenshotData,
                    windowBoundsAX: CGRect(
                        x: captured.target.x, y: captured.target.y,
                        width: captured.target.width, height: captured.target.height
                    )
                ),
                runID: context.runID
            )
            // The URL lives in the browser's address text field.
            let url = snapshot?.elements.first {
                $0.role == .textField && ($0.label ?? "").localizedCaseInsensitiveContains("address")
                    || ($0.label ?? "").localizedCaseInsensitiveContains("search")
            }?.value

            var lines = [
                "browser: \(captured.target.bundleID)",
                "title: \(captured.target.title)",
            ]
            if let url, !url.isEmpty { lines.append("url: \(url)") }
            let ids = index.entries.map(\.compactID)
            lines.append("elements: \(ids.count)" + (ids.isEmpty ? "" : " (ids \(ids[0])…\(ids[ids.count - 1]))"))
            if let text = captured.accessibilitySnapshot {
                lines.append("snapshot:\n\(text)")
            }
            return .text(call.id, lines.joined(separator: "\n"))
        }
    }
}
