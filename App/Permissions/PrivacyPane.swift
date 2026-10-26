import AppKit

enum PrivacyPane: String, CaseIterable {
    case accessibility
    case screenRecording
    case inputMonitoring
    case microphone

    var anchor: String {
        switch self {
        case .accessibility: "Privacy_Accessibility"
        case .screenRecording: "Privacy_ScreenCapture"
        case .inputMonitoring: "Privacy_ListenEvent"
        case .microphone: "Privacy_Microphone"
        }
    }

    var url: URL { URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)")! }
    var legacyURL: URL { URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")! }

    var supportsDrag: Bool { self != .microphone }
    var relaunchLikelyAfterGrant: Bool { self == .screenRecording || self == .inputMonitoring }

    func displayName(osMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) -> String {
        switch self {
        case .accessibility: osMajor >= 27 ? "Device Control and Data Access" : "Accessibility"
        case .screenRecording: "Screen & System Audio Recording"
        case .inputMonitoring: "Input Monitoring"
        case .microphone: "Microphone"
        }
    }

    @discardableResult
    func open() -> Bool {
        NSWorkspace.shared.open(url) || NSWorkspace.shared.open(legacyURL)
    }
}
