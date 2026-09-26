import Foundation
import PerryBrain
import PerryGuide

/// Shared per-thread observation state for the agent tool surface: the last
/// `screen.observe` result (compact element index + window identity), so a
/// later `ui.click "e12"` or `ring "e4"` resolves against what the model saw.
final class AgentObservationStore: @unchecked Sendable {
    struct Snapshot: Sendable {
        var index: ElementIndex
        var window: CuaWindowTarget?
        var screenshotData: Data?
        /// AX-space bounds of the captured window (for ink accent sampling).
        var windowBoundsAX: CGRect?
    }

    static let shared = AgentObservationStore()

    private var snapshots: [String: Snapshot] = [:]
    private let lock = NSLock()
    private let fallbackKey = ""

    func store(_ snapshot: Snapshot, threadID: String?) {
        lock.lock()
        defer { lock.unlock() }
        snapshots[threadID ?? fallbackKey] = snapshot
    }

    func snapshot(threadID: String?) -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        return snapshots[threadID ?? fallbackKey]
    }

    /// Resolves a compact id ("e12") or raw coordinates to an element rect in
    /// AX space. Returns nil when nothing resolves — callers surface an
    /// honest "stale observation" error rather than clicking blind.
    func resolveElement(_ elementID: String, threadID: String?) -> ObservedElement? {
        snapshot(threadID: threadID)?.index.element(for: elementID)
    }
}
