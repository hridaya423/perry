import Foundation

public enum PerryCaptureError: Error, Equatable, LocalizedError, Sendable {
    case screenRecordingPermission(PerryPermissionStatus)
    case noDisplayAvailable
    case blockedWindow
    case selectedRegionNotOnSingleDisplay
    case noImageCaptured
    case imageEncodingFailed
    case imageCropFailed
    case invalidImageData
    case visionRecognitionFailed(String)
    case captureFailed(String)

    public var errorDescription: String? {
        switch self {
        case .screenRecordingPermission(.notDetermined):
            return "I need Screen Recording access. Turn it on for Perry in System Settings."
        case .screenRecordingPermission(.denied):
            return "I need Screen Recording access. Turn it on for Perry in System Settings."
        case .screenRecordingPermission(.granted):
            return "I need Screen Recording access. Turn it on for Perry in System Settings."
        case .noDisplayAvailable:
            return "I couldn’t find a screen to capture."
        case .blockedWindow:
            return "I didn’t capture the screen because a password or payment window is open. Close it and try again."
        case .selectedRegionNotOnSingleDisplay:
            return "That area covers more than one screen. Pick an area on one screen."
        case .noImageCaptured:
            return "I couldn’t capture the screen. Try again."
        case .imageEncodingFailed:
            return "I couldn’t process the screenshot. Try again."
        case .imageCropFailed:
            return "I couldn’t crop that area. Try again."
        case .invalidImageData:
            return "I couldn’t process the screenshot. Try again."
        case .visionRecognitionFailed:
            return "I couldn’t read the text on screen. Try again."
        case .captureFailed:
            return "I couldn’t capture the screen. Try again."
        }
    }
}
