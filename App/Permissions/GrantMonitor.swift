import AppKit
import PerryCapture

enum PermissionCheck {
    static let flag = "--check-permission"

    static func granted(_ pane: PrivacyPane) -> Bool {
        switch pane {
        case .accessibility: PerryPermissionProbe.checkAccessibility()
        case .screenRecording: PerryPermissionProbe.checkScreenRecording().isUsable
        case .inputMonitoring: PerryPermissionProbe.checkInputMonitoring()
        case .microphone: PerryPermissionProbe.checkMicrophone().isUsable
        }
    }

    static func output(for arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let pane = arguments.indices.contains(index + 1) ? PrivacyPane(rawValue: arguments[index + 1]) : nil
        return #"{"granted":\#(pane.map(granted) ?? false)}"#
    }

    static func freshProcessGranted(_ pane: PrivacyPane) async -> Bool {
        guard let executable = Bundle.main.executableURL else { return false }
        return await Task.detached {
            let process = Process()
            let output = Pipe()
            process.executableURL = executable
            process.arguments = [flag, pane.rawValue]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return false }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Bool]
            return reply?["granted"] == true
        }.value
    }
}

@MainActor
final class GrantMonitor {
    enum Status: Equatable {
        case notGranted
        case granted
        case needsRelaunch
    }

    typealias Reading = (fresh: Bool, inProcess: Bool)

    static func status(for pane: PrivacyPane, grantedInFreshProbe fresh: Bool, grantedInProcess inProcess: Bool) -> Status {
        if inProcess { return .granted }
        if fresh, pane.relaunchLikelyAfterGrant { return .needsRelaunch }
        return fresh ? .granted : .notGranted
    }

    static func liveReading(_ pane: PrivacyPane) async -> Reading {
        let inProcess = PermissionCheck.granted(pane)
        guard !inProcess, pane.relaunchLikelyAfterGrant else { return (inProcess, inProcess) }
        return (await PermissionCheck.freshProcessGranted(pane), inProcess)
    }

    var onStatus: (Status) -> Void = { _ in }
    private let read: (PrivacyPane) async -> Reading
    private let idleInterval: Duration
    private let fastInterval: Duration
    private var fastUntil = ContinuousClock.now
    private var task: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    init(
        read: @escaping (PrivacyPane) async -> Reading = GrantMonitor.liveReading,
        idleInterval: Duration = .milliseconds(750),
        fastInterval: Duration = .milliseconds(250)
    ) {
        self.read = read
        self.idleInterval = idleInterval
        self.fastInterval = fastInterval
    }

    func start(pane: PrivacyPane) {
        stop()
        observers = [
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.TCC.updated"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.noteDropped() }
            },
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.noteDropped() }
            },
        ]
        task = Task { [weak self] in
            var last: Status?
            while !Task.isCancelled, let self {
                let reading = await read(pane)
                let status = Self.status(for: pane, grantedInFreshProbe: reading.fresh, grantedInProcess: reading.inProcess)
                if status != last {
                    last = status
                    onStatus(status)
                }
                if status == .granted { return }
                try? await Task.sleep(for: ContinuousClock.now < fastUntil ? fastInterval : idleInterval)
            }
        }
    }

    func noteDropped() {
        fastUntil = ContinuousClock.now + .seconds(5)
    }

    func stop() {
        task?.cancel()
        task = nil
        observers.forEach { NotificationCenter.default.removeObserver($0); DistributedNotificationCenter.default().removeObserver($0) }
        observers = []
    }

    static var reopensOnQuit = false

    static func relaunchSelf(beforeQuit: () -> Void = {}) {
        beforeQuit()
        reopensOnQuit = true
        NSApp.terminate(nil)
    }

    static func reopenAfterQuit() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? process.run()
    }
}
