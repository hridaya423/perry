import AppKit
import AVFoundation
import PerryCore

public enum PerryPermissionStatus: String, Equatable, Sendable {
    case granted
    case denied
    case notDetermined

    public var isUsable: Bool { self == .granted }
}

public enum PerryPermissionProbe {
    public static func checkAccessibility() -> Bool {
        AXIsProcessTrusted()
    }

    public static func checkScreenRecording() -> PerryPermissionStatus {
        CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    /// Shows the system prompt when the OS allows one and registers Perry in
    /// the Screen Recording list either way; returns the current grant state.
    @discardableResult
    public static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Shows the Accessibility prompt when the OS allows one; returns the
    /// current grant state.
    @discardableResult
    public static func requestAccessibility() -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    }

    /// Push-to-talk's event tap needs Input Monitoring (listen-event) access;
    /// without it the tap fails and the shortcut is dead in other apps.
    public static func checkInputMonitoring() -> Bool {
        CGPreflightListenEventAccess()
    }

    /// Shows the system prompt when the OS allows one; returns the current
    /// grant state.
    @discardableResult
    public static func requestInputMonitoring() -> Bool {
        CGRequestListenEventAccess()
    }

    public static func checkMicrophone() -> PerryPermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    /// Prompts only when the OS allows a prompt (notDetermined); never nags.
    public static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}

public struct PerryPermissionSnapshot: Equatable, Sendable {
    public let accessibility: Bool
    public let screenRecording: PerryPermissionStatus
    public let microphone: PerryPermissionStatus
    public let inputMonitoring: Bool

    public init(
        accessibility: Bool,
        screenRecording: PerryPermissionStatus,
        microphone: PerryPermissionStatus,
        inputMonitoring: Bool = false
    ) {
        self.accessibility = accessibility
        self.screenRecording = screenRecording
        self.microphone = microphone
        self.inputMonitoring = inputMonitoring
    }

    /// True when every permission Guide and Do modes rely on is usable.
    public var allGranted: Bool {
        accessibility && screenRecording.isUsable && microphone.isUsable
    }

    public var requiredPermissionsGranted: Bool {
        accessibility && screenRecording.isUsable
    }

    public static func probe() async -> PerryPermissionSnapshot {
        await Task.detached(priority: .userInitiated) {
            PerryPermissionSnapshot(
                accessibility: PerryPermissionProbe.checkAccessibility(),
                screenRecording: PerryPermissionProbe.checkScreenRecording(),
                microphone: PerryPermissionProbe.checkMicrophone(),
                inputMonitoring: PerryPermissionProbe.checkInputMonitoring()
            )
        }.value
    }
}
