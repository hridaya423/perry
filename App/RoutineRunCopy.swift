import Foundation
import PerryGuide

enum RoutineRunCopy {
    static func success(priorVerifiedRuns: Int) -> String? {
        priorVerifiedRuns == 0 ? "Done. I’ll remember this routine." : nil
    }

    static func step(of error: RoutineReplayError) -> Int? {
        switch error {
        case .targetNotFound(let step), .ambiguousTarget(let step), .missingVisualBaseline(let step), .unsupportedShortcut(let step):
            step
        default:
            nil
        }
    }

    static func stopped(routine: LearnedRoutine, step: Int?, error: RoutineReplayError?, reason: String) -> String {
        guard let step else { return "I stopped before the first step. \(sentence(reason))" }
        let label = routine.steps.indices.contains(step) ? routine.steps[step].target?.label : nil
        let head = "I stopped at step \(step + 1)."
        switch error {
        case .targetNotFound:
            return label.map { "\(head) I couldn’t find “\($0)”." } ?? "\(head) I couldn’t find that control."
        case .ambiguousTarget:
            return label.map { "\(head) More than one control looks like “\($0)”." } ?? "\(head) More than one control looks right."
        default:
            return "\(head) \(sentence(reason))"
        }
    }

    private static func sentence(_ reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        guard let first = trimmed.first else { return "" }
        return first.uppercased() + trimmed.dropFirst() + "."
    }
}
