import Foundation
import PerryCore
import PerryOverlay

/// "Show me everything": paints the full annotated path at once — numbered
/// markers plus arrows over a transparent overlay (PRD §4 Guide mode).
public struct EverythingViewPlan: Equatable, Sendable {
    public struct Marker: Equatable, Sendable, Identifiable {
        public let id: Int
        public let number: Int
        public let position: CGPointShim
        public let caption: String

        public init(id: Int, number: Int, position: CGPointShim, caption: String) {
            self.id = id
            self.number = number
            self.position = position
            self.caption = caption
        }
    }

    public struct Connector: Equatable, Sendable {
        public let fromMarkerID: Int
        public let toMarkerID: Int

        public init(from fromMarkerID: Int, to toMarkerID: Int) {
            self.fromMarkerID = fromMarkerID
            self.toMarkerID = toMarkerID
        }
    }

    public let goal: String
    public let markers: [Marker]
    public let connectors: [Connector]

    public init(goal: String, markers: [Marker], connectors: [Connector]) {
        self.goal = goal
        self.markers = markers
        self.connectors = connectors
    }
}

public enum EverythingViewBuilder {
    /// Converts the visible-path steps plus the AX snapshot they were grounded
    /// in into a paintable overlay plan. Steps whose targets are missing or
    /// verbal are skipped rather than drawn in the wrong place.
    public static func build(steps: [GuideStep], snapshot: AXSnapshot, goal: String = "") -> EverythingViewPlan? {
        var markers: [EverythingViewPlan.Marker] = []

        for (index, step) in steps.enumerated() {
            guard case .axElement(let stableID) = step.target,
                  let element = snapshot.element(withStableID: stableID) else { continue }
            let center = element.center
            markers.append(
                EverythingViewPlan.Marker(
                    id: index,
                    number: markers.count + 1,
                    position: center,
                    caption: element.label ?? step.instruction
                )
            )
        }

        guard !markers.isEmpty else { return nil }

        return EverythingViewPlan(goal: goal, markers: markers, connectors: zip(markers.dropFirst(), markers).map { next, current in
            EverythingViewPlan.Connector(from: current.id, to: next.id)
        })
    }
}

/// Grammar for spoken/typed guide requests. PRD §4: type and talk co-equal.
public enum GuideIntentParser {
    public enum Intent: Equatable, Sendable {
        case guide(goal: String)
        case showEverything(goal: String)
        case doTask(goal: String)
        case dismiss
        case notAGuideRequest
    }

    private static let guideTriggers = ["show me", "teach me", "guide me", "how do i", "help me"]
    private static let everythingTriggers = ["show me everything", "paint it all", "show all steps"]
    private static let doTriggers = ["perry, do", "do this for me", "take over"]

    public static func parse(_ input: String) -> Intent {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .notAGuideRequest }
        let lowered = text.lowercased()

        if lowered == "stop" || lowered == "dismiss" || lowered == "cancel" {
            return .dismiss
        }

        for trigger in everythingTriggers where lowered.hasPrefix(trigger) {
            return .showEverything(goal: extractGoal(text, prefix: trigger))
        }
        for trigger in doTriggers where lowered.hasPrefix(trigger) {
            return .doTask(goal: extractGoal(text, prefix: trigger))
        }
        for trigger in guideTriggers where lowered.hasPrefix(trigger) {
            return .guide(goal: extractGoal(text, prefix: trigger))
        }
        return .notAGuideRequest
    }

    private static func extractGoal(_ text: String, prefix: String) -> String {
        var remainder = text.dropFirst(prefix.count)
            .drop(while: { $0 == ":" || $0 == " " })
        // "how do I X" reads better as a goal without the stray pronoun.
        if prefix == "how do i", remainder.lowercased().hasPrefix("i ") {
            remainder = remainder.dropFirst(2)
        }
        let cleaned = remainder.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        return cleaned.isEmpty ? text : cleaned
    }
}
