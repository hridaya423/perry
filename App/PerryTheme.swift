import AppKit
import PerryOverlay
import SwiftUI

enum PerryTheme {
    enum Colors {
        static let canvas = color(light: 0xF5F3EE, dark: 0x0C0D0E)
        static let surface = color(light: 0xFFFEFA, dark: 0x18191B)
        static let text = color(light: 0x202420, dark: 0xF3F0E8)
        static let textSecondary = color(light: 0x666D66, dark: 0xAAA9A5)
        static let subtleSeparator = color(light: 0xDCDDD5, dark: 0x303234)
        static let primaryAction = color(light: 0x202420, dark: 0xF3F0E8)
        static let onPrimaryAction = color(light: 0xFFFEFA, dark: 0x0C0D0E)
        static let cameraCrown = Color.black
        static let accent = color(light: 0x3C7765, dark: 0x9CCBB6)
        static let onAccent = color(light: 0xFFFEFA, dark: 0x202420)
        static let success = Color(nsColor: .systemGreen)
        static let caution = Color(nsColor: .systemYellow)
        static let warning = Color(nsColor: .systemOrange)
        static let danger = Color(nsColor: .systemRed)
        static let active = Color(nsColor: .systemBlue)
        static let focus = accent

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

    enum Elevation {
        static let shadow = PerryOverlayTheme.Colors.shadow
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

    enum Spacing {
        static let label = CGFloat(1)
        static let tight = CGFloat(2)
        static let control = CGFloat(6)
        static let inline = CGFloat(8)
        static let header = CGFloat(10)
        static let section = CGFloat(12)
        static let panelInset = CGFloat(16)
        static let cardInset = CGFloat(18)
    }

    enum Radius {
        static let panel = CGFloat(18)
    }

    enum Sizing {
        static let panelWidth = CGFloat(480)
        static let panelHeight = CGFloat(380)
        static let onboardingContentWidth = CGFloat(560)
        static let onboardingContentHeight = CGFloat(430)
        static let settingsWidth = CGFloat(760)
        static let settingsHeight = CGFloat(520)
        static let settingsMinimumWidth = CGFloat(680)
        static let settingsMinimumHeight = CGFloat(480)
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
        static let settle = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.42)
    }
}
