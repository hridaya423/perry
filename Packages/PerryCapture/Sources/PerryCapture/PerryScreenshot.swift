import Foundation

public struct PerryScreenCapture: Equatable, Sendable {
    public let imageData: Data
    public let label: String
    public let appName: String?
    public let bundleIdentifier: String?
    public let isCursorScreen: Bool
    public let displayWidthInPoints: Int
    public let displayHeightInPoints: Int
    public let displayNativeWidthInPixels: Int?
    public let displayNativeHeightInPixels: Int?
    public let displayFrame: CGRect
    public let screenshotWidthInPixels: Int
    public let screenshotHeightInPixels: Int

    public init(
        imageData: Data,
        label: String,
        appName: String?,
        bundleIdentifier: String?,
        isCursorScreen: Bool,
        displayWidthInPoints: Int,
        displayHeightInPoints: Int,
        displayNativeWidthInPixels: Int?,
        displayNativeHeightInPixels: Int?,
        displayFrame: CGRect,
        screenshotWidthInPixels: Int,
        screenshotHeightInPixels: Int
    ) {
        self.imageData = imageData
        self.label = label
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.isCursorScreen = isCursorScreen
        self.displayWidthInPoints = displayWidthInPoints
        self.displayHeightInPoints = displayHeightInPoints
        self.displayNativeWidthInPixels = displayNativeWidthInPixels
        self.displayNativeHeightInPixels = displayNativeHeightInPixels
        self.displayFrame = displayFrame
        self.screenshotWidthInPixels = screenshotWidthInPixels
        self.screenshotHeightInPixels = screenshotHeightInPixels
    }

    public init(
        imageData: Data,
        displayFrame: CGRect,
        screenshotWidthInPixels: Int,
        screenshotHeightInPixels: Int,
        label: String = "screen",
        appName: String? = nil,
        bundleIdentifier: String? = nil,
        isCursorScreen: Bool = false,
        displayNativeWidthInPixels: Int? = nil,
        displayNativeHeightInPixels: Int? = nil
    ) {
        self.init(
            imageData: imageData,
            label: label,
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            isCursorScreen: isCursorScreen,
            displayWidthInPoints: Int(displayFrame.width.rounded()),
            displayHeightInPoints: Int(displayFrame.height.rounded()),
            displayNativeWidthInPixels: displayNativeWidthInPixels,
            displayNativeHeightInPixels: displayNativeHeightInPixels,
            displayFrame: displayFrame,
            screenshotWidthInPixels: screenshotWidthInPixels,
            screenshotHeightInPixels: screenshotHeightInPixels
        )
    }

    public func screenRect(forVisionBoundingBox boundingBox: CGRect) -> CGRect {
        let box = boundingBox.standardized
        return CGRect(
            x: displayFrame.minX + box.minX * displayFrame.width,
            y: displayFrame.minY + box.minY * displayFrame.height,
            width: box.width * displayFrame.width,
            height: box.height * displayFrame.height
        )
    }

    public func pixelRect(forScreenRect screenRect: CGRect) -> CGRect? {
        guard displayFrame.width > 0,
              displayFrame.height > 0,
              screenshotWidthInPixels > 0,
              screenshotHeightInPixels > 0,
              screenRect.width > 0,
              screenRect.height > 0 else {
            return nil
        }

        let clipped = screenRect.intersection(displayFrame)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }

        let imageWidth = CGFloat(screenshotWidthInPixels)
        let imageHeight = CGFloat(screenshotHeightInPixels)
        let x = (clipped.minX - displayFrame.minX) / displayFrame.width * imageWidth
        let y = (displayFrame.maxY - clipped.maxY) / displayFrame.height * imageHeight
        let width = clipped.width / displayFrame.width * imageWidth
        let height = clipped.height / displayFrame.height * imageHeight
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
