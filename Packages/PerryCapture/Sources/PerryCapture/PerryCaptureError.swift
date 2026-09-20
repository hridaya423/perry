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
            return "Screen Recording permission has not been granted yet."
        case .screenRecordingPermission(.denied):
            return "Screen Recording permission is denied. Enable it in System Settings > Privacy & Security > Screen Recording."
        case .screenRecordingPermission(.granted):
            return "Screen Recording permission is required for this capture."
        case .noDisplayAvailable:
            return "No display is available for capture."
        case .blockedWindow:
            return "Capture refused because a sensitive window is visible."
        case .selectedRegionNotOnSingleDisplay:
            return "The selected region is not fully contained by one display."
        case .noImageCaptured:
            return "Capture returned no image."
        case .imageEncodingFailed:
            return "The image could not be encoded."
        case .imageCropFailed:
            return "The selected region could not be cropped."
        case .invalidImageData:
            return "The image data could not be decoded."
        case .visionRecognitionFailed(let detail):
            return "Vision text recognition failed: \(detail)"
        case .captureFailed(let detail):
            return "Image capture failed: \(detail)"
        }
    }
}
