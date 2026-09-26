import CoreGraphics
import Foundation
import ImageIO
import PerryOverlay

/// Picks an ink accent by sampling a ~24 pt patch of the turn's in-memory
/// screenshot at the marked element's center — never a fresh capture (§5:
/// marks must read on whatever is behind them). Returns nil when the patch
/// cannot be mapped, so callers keep the default accent.
enum InkAccentSampler {
    /// - Parameters:
    ///   - imageJPEG: the observation's screenshot bytes (target-window capture).
    ///   - elementCenterAX: marked element center, AX top-left screen points.
    ///   - windowBoundsAX: captured window bounds, AX top-left screen points.
    static func accentHex(
        imageJPEG: Data,
        elementCenterAX: CGPoint,
        windowBoundsAX: CGRect
    ) -> String? {
        guard windowBoundsAX.width > 0, windowBoundsAX.height > 0,
              let source = CGImageSourceCreateWithData(imageJPEG as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let scaleX = CGFloat(image.width) / windowBoundsAX.width
        let scaleY = CGFloat(image.height) / windowBoundsAX.height
        let patch = CGRect(
            x: (elementCenterAX.x - windowBoundsAX.minX) * scaleX - 12,
            y: (elementCenterAX.y - windowBoundsAX.minY) * scaleY - 12,
            width: 24,
            height: 24
        ).integral.intersection(
            CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        guard !patch.isNull, patch.width >= 4, patch.height >= 4,
              let crop = image.cropping(to: patch) else { return nil }

        // Downscale to 4×4 RGBA and take the mean luma.
        let w = 4, h = 4
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drew = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drew,
              let luma = pixels.withUnsafeBufferPointer({ InkColor.luminance(of: $0) })
        else { return nil }
        return InkColor.hex(forLuminance: luma)
    }
}
