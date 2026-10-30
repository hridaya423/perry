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

    public static func checkInputMonitoring() -> Bool {
        CGPreflightListenEventAccess()
    }

    public static func checkMicrophone() -> PerryPermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

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
