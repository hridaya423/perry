import Foundation

/// The full annotated path, painted at once as numbered markers over the target window.
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

    public let markers: [Marker]

    public init(markers: [Marker]) {
        self.markers = markers
    }
}

public enum EverythingViewBuilder {
    /// Steps whose targets are missing or verbal are skipped rather than drawn in the wrong place.
    public static func build(steps: [GuideStep], snapshot: AXSnapshot) -> EverythingViewPlan? {
        var markers: [EverythingViewPlan.Marker] = []
        for (index, step) in steps.enumerated() {
            guard case .axElement(let stableID) = step.target,
                  let element = snapshot.element(withStableID: stableID) else { continue }
            markers.append(
                EverythingViewPlan.Marker(
                    id: index,
                    number: markers.count + 1,
                    position: element.center,
                    caption: element.label ?? step.instruction
                )
            )
        }
        return markers.isEmpty ? nil : EverythingViewPlan(markers: markers)
    }
}

/// Grammar for spoken and typed guide requests.
public enum GuideIntentParser {
    public enum Intent: Equatable, Sendable {
        case guide(goal: String)
        case showEverything(goal: String)
        case doTask(goal: String)
        case dismiss
        case notAGuideRequest
    }

    private static let guideTriggers = ["show me", "teach me", "guide me", "how do i"]
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
        if prefix == "how do i", remainder.lowercased().hasPrefix("i ") {
            remainder = remainder.dropFirst(2)
        }
        let cleaned = remainder.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        return cleaned.isEmpty ? text : cleaned
    }
}
