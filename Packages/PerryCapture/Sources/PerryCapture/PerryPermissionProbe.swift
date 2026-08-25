import AppKit
import AVFoundation
import PerryCore

public enum PerryPermissionStatus: String, Sendable {
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

    public init(
        accessibility: Bool,
        screenRecording: PerryPermissionStatus,
        microphone: PerryPermissionStatus
    ) {
        self.accessibility = accessibility
        self.screenRecording = screenRecording
        self.microphone = microphone
    }

    /// True when every permission Guide and Do modes rely on is usable.
    public var allGranted: Bool {
        accessibility && screenRecording.isUsable && microphone.isUsable
    }

    public static func probe() -> PerryPermissionSnapshot {
        PerryPermissionSnapshot(
            accessibility: PerryPermissionProbe.checkAccessibility(),
            screenRecording: PerryPermissionProbe.checkScreenRecording(),
            microphone: PerryPermissionProbe.checkMicrophone()
        )
    }
}
