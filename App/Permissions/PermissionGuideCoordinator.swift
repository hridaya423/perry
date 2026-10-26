import AppKit
import Combine
import SwiftUI

@MainActor
final class PermissionGuideCoordinator: ObservableObject {
    struct Surface {
        var show: (NSRect) -> Void
        var move: (NSRect) -> Void
        var setHidden: (Bool) -> Void
        var setDragging: (Bool) -> Void = { _ in }
        var close: () -> Void
    }

    private static var active: PermissionGuideCoordinator?

    @Published private(set) var phase: PermissionHelperView.Phase = .instruction
    let pane: PrivacyPane
    let bundleURL: URL
    private let isGranted: (PrivacyPane) -> Bool
    private let open: (PrivacyPane) -> Void
    private let tracker: SettingsWindowTracker
    private let monitor: GrantMonitor
    private let visibleFrame: (NSRect) -> NSRect
    private let retryAfter: Duration
    private let grantedHold: Duration
    var surface = Surface(show: { _ in }, move: { _ in }, setHidden: { _ in }, close: {})
    private var continuation: CheckedContinuation<GrantMonitor.Status, Never>?
    private var retryTask: Task<Void, Never>?
    private var lastStatus: GrantMonitor.Status = .notGranted

    init(
        pane: PrivacyPane,
        bundleURL: URL = Bundle.main.bundleURL,
        isGranted: @escaping (PrivacyPane) -> Bool = PermissionCheck.granted,
        open: @escaping (PrivacyPane) -> Void = { $0.open() },
        tracker: SettingsWindowTracker? = nil,
        monitor: GrantMonitor? = nil,
        visibleFrame: @escaping (NSRect) -> NSRect = PermissionGuideCoordinator.visibleFrame(around:),
        retryAfter: Duration = .seconds(15),
        grantedHold: Duration = .seconds(1)
    ) {
        self.pane = pane
        self.bundleURL = bundleURL
        self.isGranted = isGranted
        self.open = open
        self.tracker = tracker ?? SettingsWindowTracker()
        self.monitor = monitor ?? GrantMonitor()
        self.visibleFrame = visibleFrame
        self.retryAfter = retryAfter
        self.grantedHold = grantedHold
    }

    static func canGrant(from bundleURL: URL) -> Bool {
        let path = bundleURL.standardizedFileURL.path
        return !path.contains("/AppTranslocation/") && !path.hasPrefix("/Volumes/")
    }

    @discardableResult
    static func guide(_ pane: PrivacyPane, from source: NSRect? = nil) async -> GrantMonitor.Status {
        active?.finish(.notGranted)
        let guide = PermissionGuideCoordinator(pane: pane)
        let panel = PermissionHelperPanel()
        panel.show(PermissionGuideHost(guide: guide))
        let origin = source ?? NSRect(x: (NSScreen.main?.frame.midX ?? 0) - 1, y: NSScreen.main?.frame.maxY ?? 0, width: 2, height: 2)
        guide.surface = Surface(
            show: { panel.flyIn(from: origin, to: $0) },
            move: { panel.follow($0) },
            setHidden: { hidden in
                if hidden {
                    panel.fadeOut()
                } else {
                    panel.alphaValue = 1
                    panel.orderFrontRegardless()
                }
            },
            setDragging: { panel.setDragging($0) },
            close: { panel.fadeOut { panel.close() } }
        )
        active = guide
        let status = await guide.present()
        if active === guide { active = nil }
        return status
    }

    func present() async -> GrantMonitor.Status {
        if isGranted(pane) { return .granted }
        guard Self.canGrant(from: bundleURL) else {
            phase = .wrongLocation
            let screen = visibleFrame(.zero)
            surface.show(NSRect(
                x: screen.midX - PermissionHelperPanel.cardSize.width / 2,
                y: screen.maxY - PermissionHelperPanel.cardSize.height - 12,
                width: PermissionHelperPanel.cardSize.width,
                height: PermissionHelperPanel.cardSize.height
            ))
            return await withCheckedContinuation { continuation = $0 }
        }
        open(pane)
        let window = await tracker.waitForStableFrame()
        phase = .instruction
        surface.show(window.map(dock) ?? dock(SettingsWindowSnapshot(id: 0, frame: visibleFrame(.zero))))
        tracker.onChange = { [weak self] snapshot in
            guard let self else { return }
            surface.move(dock(snapshot))
            if phase == .settingsClosed { phase = .instruction }
        }
        tracker.onGone = { [weak self] in
            guard let self, phase != .granted else { return }
            phase = .settingsClosed
            surface.setHidden(false)
        }
        tracker.start()
        monitor.onStatus = { [weak self] in self?.statusChanged($0) }
        monitor.start(pane: pane)
        return await withCheckedContinuation { continuation = $0 }
    }

    func dragBegan() {
        retryTask?.cancel()
        surface.setDragging(true)
    }

    func dragEnded(accepted: Bool) {
        surface.setDragging(false)
        guard accepted else { return }
        surface.setHidden(true)
        monitor.noteDropped()
        retryTask = Task { [weak self, retryAfter] in
            try? await Task.sleep(for: retryAfter)
            guard !Task.isCancelled, let self, phase == .instruction || phase == .retry else { return }
            phase = .retry
            surface.setHidden(false)
        }
    }

    func reopenSettings() {
        open(pane)
    }

    func restart() {
        GrantMonitor.relaunchSelf()
    }

    func close() {
        finish(lastStatus)
    }

    private func statusChanged(_ status: GrantMonitor.Status) {
        lastStatus = status
        switch status {
        case .notGranted:
            return
        case .needsRelaunch:
            retryTask?.cancel()
            phase = .restart
            surface.setHidden(false)
        case .granted:
            retryTask?.cancel()
            phase = .granted
            surface.setHidden(false)
            Task { [weak self, grantedHold] in
                try? await Task.sleep(for: grantedHold)
                self?.finish(.granted)
            }
        }
    }

    private func finish(_ status: GrantMonitor.Status) {
        retryTask?.cancel()
        tracker.stop()
        monitor.stop()
        surface.close()
        continuation?.resume(returning: status)
        continuation = nil
    }

    private func dock(_ snapshot: SettingsWindowSnapshot) -> NSRect {
        SettingsWindowTracker.dockFrame(settings: snapshot.frame, visible: visibleFrame(snapshot.frame), cardHeight: PermissionHelperPanel.cardSize.height)
    }

    static func visibleFrame(around frame: NSRect) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main
        return screen?.visibleFrame ?? .zero
    }
}

private struct PermissionGuideHost: View {
    @ObservedObject var guide: PermissionGuideCoordinator

    var body: some View {
        PermissionHelperView(
            pane: guide.pane,
            appURL: guide.bundleURL,
            phase: guide.phase,
            actions: .init(
                dragBegan: guide.dragBegan,
                dragEnded: { guide.dragEnded(accepted: $0) },
                reopenSettings: guide.reopenSettings,
                restart: guide.restart,
                close: guide.close
            )
        )
    }
}
