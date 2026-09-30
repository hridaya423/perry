import AppKit
import PerryOverlay
import SwiftUI

enum PerryTheme {
    enum Colors {
        // Canvas and surfaces
        static let canvas = Color(nsColor: .underPageBackgroundColor)
        static let surface = Color(nsColor: .controlBackgroundColor)

        // Text
        static let text = Color.primary
        static let textSecondary = Color.secondary

        // Accent
        static let accent = Color(nsColor: NSColor(name: nil) { appearance in
            if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
                return NSColor(srgbRed: 0.204, green: 0.827, blue: 0.600, alpha: 1)
            }
            return NSColor(srgbRed: 0.055, green: 0.400, blue: 0.286, alpha: 1)
        })
        static let onAccent = Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.024, green: 0.110, blue: 0.070, alpha: 1)
                : .white
        })

        // Status
        static let success = Color(nsColor: .systemGreen)
        static let caution = Color(nsColor: .systemYellow)
        static let warning = Color(nsColor: .systemOrange)
        static let danger = Color(nsColor: .systemRed)
        static let active = Color(nsColor: .systemBlue)

        // Focus
        static let focus = accent
    }

    enum Elevation {
        static let shadow = PerryOverlayTheme.Colors.shadow
    }

    enum Typography {
        static let panelTitle = Font.system(.headline, design: .rounded, weight: .bold)
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
        static let value = Font.system(.caption, design: .monospaced)
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
        static let panelHeight = CGFloat(440)
        static let settingsWidth = CGFloat(760)
        static let settingsHeight = CGFloat(520)
        static let settingsMinimumWidth = CGFloat(680)
        static let settingsMinimumHeight = CGFloat(480)
        static let iconButton = CGFloat(32)
        static let statusDot = CGFloat(7)
        static let progressWidth = CGFloat(70)
        static let protocolPickerWidth = CGFloat(190)
        static let speechRateValueWidth = CGFloat(34)
        static let realtimeRateValueWidth = CGFloat(42)
        static let captionOpacityValueWidth = CGFloat(36)
        static let workspaceApprovalMinimumWidth = CGFloat(480)
        static let workspaceApprovalWidth = CGFloat(560)
        static let workspaceApprovalMinimumHeight = CGFloat(340)
        static let workspaceApprovalHeight = CGFloat(440)
        static let filePreviewMinimumHeight = CGFloat(140)
    }

    enum Motion {
        static let panelStateChange = Animation.easeOut(duration: 0.16)
    }
}
