import Foundation
import PerryBrain
import PerryGuide

final class AgentObservationStore: @unchecked Sendable {
    struct Snapshot: Sendable {
        var index: ElementIndex
        var window: ScreenWindowTarget?
        var screenshotData: Data?
        var windowBoundsAX: CGRect?
        var imageSize: CGSize?
        var driverScale = 1.0

        func screenPoint(fromImage point: CGPoint) -> CGPoint {
            guard let bounds = windowBoundsAX, let imageSize, imageSize.width > 0 else { return point }
            let scale = imageSize.width / bounds.width
            return CGPoint(x: bounds.minX + point.x / scale, y: bounds.minY + point.y / scale)
        }

        func imageRect(fromScreen rect: CGRect) -> CGRect {
            guard let bounds = windowBoundsAX, let imageSize, imageSize.width > 0, bounds.width > 0 else { return rect }
            let scale = imageSize.width / bounds.width
            return CGRect(x: (rect.minX - bounds.minX) * scale, y: (rect.minY - bounds.minY) * scale, width: rect.width * scale, height: rect.height * scale)
        }
    }

    static let shared = AgentObservationStore()

    private struct Context {
        var target: ScreenTargetHint?
        var snapshot: Snapshot?
    }

    private var contexts: [UUID: Context] = [:]
    private var generations: [UUID: Int] = [:]
    private let lock = NSLock()

    func setTarget(_ target: ScreenTargetHint, runID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        contexts[runID] = Context(target: target)
    }

    func prepareCapture(runID: UUID, bundleID: String? = nil, windowTitle: String? = nil) throws -> ScreenTargetHint {
        lock.lock()
        defer { lock.unlock() }
        let bundleID = bundleID.flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let windowTitle = windowTitle.flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let previous = contexts[runID]?.target
        let sameApp = bundleID.map { previous?.bundleID?.caseInsensitiveCompare($0) == .orderedSame } ?? true
        let sameWindow = windowTitle.map { previous?.windowTitle?.caseInsensitiveCompare($0) == .orderedSame } ?? true
        let hint = ScreenTargetHint(
            bundleID: bundleID ?? previous?.bundleID,
            processID: sameApp ? previous?.processID : nil,
            windowID: sameApp && sameWindow ? previous?.windowID : nil,
            windowTitle: windowTitle ?? (sameApp ? previous?.windowTitle : nil)
        )
        guard hint.bundleID != nil || hint.processID != nil || hint.windowID != nil else {
            throw TargetError.required
        }
        contexts[runID] = Context(target: hint)
        return hint
    }

    private enum TargetError: LocalizedError {
        case required

        var errorDescription: String? {
            "Choose a window or specify an application before asking Perry to inspect it."
        }
    }

    func store(_ snapshot: Snapshot, runID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        let target = snapshot.window?.hint ?? contexts[runID]?.target
        contexts[runID] = Context(target: target, snapshot: snapshot)
    }

    func snapshot(runID: UUID) -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        return contexts[runID]?.snapshot
    }

    func remove(runID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        contexts[runID] = nil
        generations[runID] = nil
    }

    func restartIDs(runID: UUID) -> String {
        lock.lock()
        defer { lock.unlock() }
        generations[runID] = 1
        return "e"
    }

    func nextIDPrefix(runID: UUID) -> String {
        lock.lock()
        defer { lock.unlock() }
        let generation = (generations[runID] ?? 0) + 1
        generations[runID] = generation
        return generation == 1 ? "e" : "v\(generation)e"
    }

    func screenPoint(fromImage point: CGPoint, runID: UUID) -> CGPoint {
        snapshot(runID: runID)?.screenPoint(fromImage: point) ?? point
    }

    func resolveElement(_ elementID: String, runID: UUID) -> ObservedElement? {
        snapshot(runID: runID)?.index.element(for: elementID)
    }
}

extension ObservedElement {
    init(_ element: AXElement, windowID: Int, detail: ScreenElementDetail? = nil) {
        self.init(
            id: element.stableID,
            role: element.rawRole ?? "AX\(element.role.rawValue)",
            label: element.label ?? "",
            frame: CGRect(x: element.frame.x, y: element.frame.y, width: element.frame.width, height: element.frame.height),
            windowID: windowID,
            value: detail?.value
        )
    }
}

extension GuideObservation {
    var observedElements: [ObservedElement] {
        let observedWindowID = Int(windowID ?? 0)
        return snapshot.elements
            .filter { $0.sensitivity != .secure }
            .map { ObservedElement($0, windowID: observedWindowID) }
    }
}
