import AppKit
import PerryCapture
import PerryCore
import PerryGuide
import PerryOverlay

/// ⌥⌘-drag circle selection: the live stroke on the overlay, the selected
/// area other features read, and the one-line spoken description of it.
@MainActor
final class SpatialSelectionController {
    private let overlayState: PerryCursorState
    private let workers: CuaWorkerService
    private let targetHint: @MainActor () async -> CuaTargetHint
    private let speak: (String) -> Void
    private let setStatus: (String) -> Void
    private lazy var monitor = SpatialInputMonitor(
        onPointsChanged: { [weak self] points in self?.showStroke(points) },
        onSelection: { [weak self] selection in self?.select(selection) },
        onCancel: { [weak self] in self?.cancelSelection() }
    )
    private var describeTask: Task<Void, Never>?
    private(set) var selection: SpatialSelection?

    init(
        overlayState: PerryCursorState,
        workers: CuaWorkerService,
        targetHint: @escaping @MainActor () async -> CuaTargetHint,
        speak: @escaping (String) -> Void,
        setStatus: @escaping (String) -> Void
    ) {
        self.overlayState = overlayState
        self.workers = workers
        self.targetHint = targetHint
        self.speak = speak
        self.setStatus = setStatus
    }

    func startMonitoring() { monitor.start() }
    func stopMonitoring() { monitor.stop() }
    func clearSelection() { selection = nil }

    func cancelDescription() { describeTask?.cancel() }

    func joinDescription() async {
        await describeTask?.value
    }

    private func describe(_ selection: SpatialSelection) async {
        let snapshot: AXSnapshot?
        do {
            snapshot = try await workers.withWorker(scope: .dictation, resources: []) { worker in
                let capture = try await worker.capture(target: await self.targetHint())
                return capture.accessibilitySnapshotModel
            }
        } catch {
            snapshot = nil
        }
        let label = Self.label(for: selection.rect, snapshot: snapshot)
        overlayState.circleSelectSnapLabel = label
        speak(label == nil ? "I have the area you circled." : "I have \(label!).")
    }

    private func showStroke(_ points: [CGPoint]) {
        overlayState.circleSelectLivePoints = points
        if points.isEmpty {
            overlayState.circleSelectSnappedRect = nil
            overlayState.circleSelectSnapLabel = nil
        }
    }

    private func cancelSelection() {
        describeTask?.cancel()
        overlayState.circleSelectLivePoints = []
        overlayState.circleSelectSnappedRect = nil
        overlayState.circleSelectSnapLabel = nil
        selection = nil
        setStatus("Circle a window with ⌥⌘ and drag.")
    }

    private func select(_ selection: SpatialSelection) {
        self.selection = selection
        overlayState.circleSelectLivePoints = selection.points
        overlayState.circleSelectSnappedRect = selection.rect
        setStatus("Area selected. Tell Perry what to do there.")
        describeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.describeTask = nil }
            await self.describe(selection)
        }
    }

    private static func label(for rect: CGRect, snapshot: AXSnapshot?) -> String? {
        guard let snapshot else { return nil }
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        let axRect = CGRect(
            x: rect.minX,
            y: primaryMaxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
        let names = snapshot.actionableElements()
            .filter { element in
                let frame = CGRect(x: element.frame.x, y: element.frame.y, width: element.frame.width, height: element.frame.height)
                return frame.intersects(axRect)
            }
            .prefix(3)
            .compactMap(\.label)
        guard !names.isEmpty else { return snapshot.windowTitle.isEmpty ? nil : snapshot.windowTitle }
        return names.joined(separator: ", ")
    }
}
