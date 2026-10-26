import AppKit
import PerryOverlay
import SwiftUI

enum PerryTheme {
    enum Colors {
        static let canvas = color(light: 0xF5F3EE, dark: 0x1B1B1A)
        static let surface = color(light: 0xFFFEFA, dark: 0x252524)
        static let chip = color(light: 0xEDEAE3, dark: 0x30302E)
        static let text = color(light: 0x202420, dark: 0xF5F2EA)
        static let textSecondary = color(light: 0x666D66, dark: 0xA6A59F)
        static let textTertiary = color(light: 0x6E736E, dark: 0x8B8A85)
        static let icon = color(light: 0x4A504A, dark: 0xD2D0C9)
        static let iconNS = nsColor(light: 0x4A504A, dark: 0xD2D0C9)
        static let subtleSeparator = color(light: 0xDCDDD5, dark: 0x343432)
        static let primaryAction = color(light: 0x202420, dark: 0xF5F2EA)
        static let onPrimaryAction = color(light: 0xFFFEFA, dark: 0x0C0D0E)
        static let crown = Color.black
        static let eye = color(light: 0xF4F1E8, dark: 0xF4F1E8)
        static let accent = color(light: 0x1D7D3E, dark: 0x5EDB81)
        static let onAccent = color(light: 0xFFFEFA, dark: 0x0C0D0E)
        static let success = color(light: 0x1D7D3E, dark: 0x5EDB81)
        static let caution = color(light: 0xA05A00, dark: 0xFF9F0A)
        static let warning = caution
        static let danger = color(light: 0xD70015, dark: 0xFF6B63)

        private static func color(light: Int, dark: Int) -> Color {
            Color(nsColor: nsColor(light: light, dark: dark))
        }

        private static func nsColor(light: Int, dark: Int) -> NSColor {
            NSColor(name: nil) { appearance in
                let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
                return NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                               green: CGFloat((rgb >> 8) & 0xFF) / 255,
                               blue: CGFloat(rgb & 0xFF) / 255,
                               alpha: 1)
            }
        }
    }

    enum Typography {
        static let panelTitle = Font.system(.headline, weight: .semibold)
        static let panelBody = Font.body
        static let panelSubtitle = Font.subheadline
        static let panelMetadata = Font.system(size: 12, weight: .medium)
        static let panelClose = Font.system(size: 12, weight: .semibold)
        static let panelIcon = Font.callout.weight(.semibold)
        static let action = Font.callout.weight(.medium)
        static let settingsStatus = Font.callout
        static let note = Font.system(size: 12)
        static let mono = Font.system(size: 12, design: .monospaced)
        static let monoSmall = Font.system(size: 11, design: .monospaced)
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
        static let secondary = Font.system(size: 12)
        static let keycap = Font.system(size: 12, weight: .medium, design: .rounded)
        static let code = Font.system(size: 12, design: .monospaced)
        static let meta = Font.system(size: 11, weight: .medium).monospacedDigit()
        static let section = Font.system(size: 11, weight: .semibold)
    }

    enum Icon {
        static let utility = Font.system(size: 13, weight: .medium)
        static let rail = Font.system(size: 13)
        static let status = Font.system(size: 13, weight: .semibold)
        static let slot = CGFloat(28)
        static let hit = CGFloat(28)
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
        static let panel = CGFloat(22)
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
        static let exit = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.18)
        static let progress = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.32)
        static let draw = Animation.timingCurve(0.65, 0, 0.35, 1, duration: 0.9)
    }
}
