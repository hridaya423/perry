import AppKit
import PerryOverlay
import SwiftUI

enum PerryTheme {
    enum Colors {
        static let canvas = color(light: 0xF5F3EE, dark: 0x1A1B1D)
        static let surface = color(light: 0xFFFEFA, dark: 0x232427)
        static let chip = color(light: 0xEDEAE3, dark: 0x2C2D31)
        static let text = color(light: 0x202420, dark: 0xF5F2EA)
        static let textSecondary = color(light: 0x666D66, dark: 0xA6A59F)
        static let textTertiary = color(light: 0x6E736E, dark: 0x8B8A85)
        static let subtleSeparator = color(light: 0xDCDDD5, dark: 0x2C2D2F)
        static let primaryAction = color(light: 0x202420, dark: 0xF5F2EA)
        static let onPrimaryAction = color(light: 0xFFFEFA, dark: 0x0C0D0E)
        static let crown = Color.black
        static let eye = color(light: 0xF4F1E8, dark: 0xF4F1E8)
        static let accent = color(light: 0x3C7765, dark: 0x7BE3BD)
        static let onAccent = color(light: 0xFFFEFA, dark: 0x0C0D0E)
        static let success = color(light: 0x248A3D, dark: 0x5FD38D)
        static let caution = color(light: 0xA05A00, dark: 0xFFB020)
        static let warning = Color(nsColor: .systemOrange)
        static let danger = color(light: 0xD70015, dark: 0xFF6B63)
        static let active = Color(nsColor: .systemBlue)

        private static func color(light: Int, dark: Int) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
                return NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                               green: CGFloat((rgb >> 8) & 0xFF) / 255,
                               blue: CGFloat(rgb & 0xFF) / 255,
                               alpha: 1)
            })
        }
    }

    enum Typography {
        static let panelTitle = Font.system(.headline, weight: .semibold)
        static let panelBody = Font.body
        static let panelSubtitle = Font.subheadline
        static let panelMetadata = Font.caption.weight(.medium)
        static let panelClose = Font.caption.weight(.semibold)
        static let panelIcon = Font.callout.weight(.semibold)
        static let action = Font.callout.weight(.medium)
        static let settingsStatus = Font.callout
        static let note = Font.caption
        static let mono = Font.system(.caption, design: .monospaced)
        static let monoSmall = Font.system(.caption2, design: .monospaced)
        static let value = Font.callout.monospacedDigit()
    }

    enum Scale {
        static let display = Font.system(size: 26, weight: .semibold, design: .serif)
        static let heading = Font.system(size: 20, weight: .semibold, design: .serif)
        static let wordmark = Font.system(size: 18, weight: .semibold, design: .rounded)
        static let input = Font.system(size: 15)
        static let title = Font.system(size: 15, weight: .semibold)
        static let rowTitle = Font.system(size: 14, weight: .semibold)
        static let body = Font.system(size: 13)
        static let chip = Font.system(size: 13, weight: .medium)
        static let secondary = Font.system(size: 12.5)
        static let keycap = Font.system(size: 12, weight: .medium, design: .rounded)
        static let code = Font.system(size: 12, design: .monospaced)
        static let meta = Font.system(size: 11, weight: .medium).monospacedDigit()
        static let section = Font.system(size: 11, weight: .semibold)
    }

    enum Icon {
        static let toolbar = Font.system(size: 13, weight: .medium)
        static let row = Font.system(size: 15, weight: .medium)
        static let inline = Font.system(size: 11, weight: .semibold)
    }

    enum Spacing {
        static let label = CGFloat(1)
        static let tight = CGFloat(2)
        static let control = CGFloat(6)
        static let inline = CGFloat(8)
        static let header = CGFloat(10)
        static let section = CGFloat(12)
        static let panelInset = CGFloat(16)
    }

    enum Radius {
        static let panel = CGFloat(18)
    }

    enum Sizing {
        static let panelWidth = CGFloat(480)
        static let panelHeight = CGFloat(380)
        static let onboardingContentWidth = CGFloat(560)
        static let onboardingContentHeight = CGFloat(430)
        static let iconButton = CGFloat(32)
        static let statusDot = CGFloat(7)
        static let progressWidth = CGFloat(70)
        static let protocolPickerWidth = CGFloat(190)
        static let speechRateValueWidth = CGFloat(40)
        static let realtimeRateValueWidth = CGFloat(48)
        static let captionOpacityValueWidth = CGFloat(44)
        static let filePreviewMinimumHeight = CGFloat(140)
    }

    enum Motion {
        static let panelStateChange = Animation.easeOut(duration: 0.16)
        static let snap = Animation.snappy(duration: 0.16)
        static let glide = Animation.spring(response: 0.32, dampingFraction: 0.86)
        static let enter = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.5)
        static let draw = Animation.timingCurve(0.65, 0, 0.35, 1, duration: 0.9)
    }
}
