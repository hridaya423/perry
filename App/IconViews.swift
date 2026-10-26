import AppKit
import SwiftUI

struct LeadDisc: View {
    let systemImage: String
    let tint: Color
    var nudge = CGFloat(0)

    var body: some View {
        Image(systemName: systemImage)
            .font(PerryTheme.Icon.status)
            .foregroundStyle(tint)
            .offset(y: nudge)
            .frame(width: PerryTheme.Icon.slot, height: PerryTheme.Icon.slot)
            .background(tint.opacity(0.18), in: Circle())
    }
}

struct StatusMark: View {
    enum Kind {
        case ok
        case attention
        case failed

        var systemImage: String {
            switch self {
            case .ok: "checkmark"
            case .attention: "exclamationmark.triangle"
            case .failed: "xmark"
            }
        }

        var tint: Color {
            switch self {
            case .ok: PerryTheme.Colors.success
            case .attention: PerryTheme.Colors.caution
            case .failed: PerryTheme.Colors.danger
            }
        }
    }

    let kind: Kind
    var tint: Color?

    init(_ kind: Kind, tint: Color? = nil) {
        self.kind = kind
        self.tint = tint
    }

    var body: some View {
        Image(systemName: kind.systemImage)
            .fontWeight(.semibold)
            .foregroundStyle(tint ?? kind.tint)
    }
}

struct StatusLabel: View {
    let title: String
    let kind: StatusMark.Kind
    var tint: Color?

    init(_ title: String, _ kind: StatusMark.Kind, tint: Color? = nil) {
        self.title = title
        self.kind = kind
        self.tint = tint
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            StatusMark(kind, tint: tint)
        }
    }
}

struct LeadSpinner: View {
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(PerryTheme.Colors.accent, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spinning)
            .frame(width: PerryTheme.Icon.slot, height: PerryTheme.Icon.slot)
            .background(PerryTheme.Colors.accent.opacity(0.18), in: Circle())
            .onAppear { spinning = true }
    }
}

struct RadioMark: View {
    let selected: Bool

    var body: some View {
        Circle()
            .strokeBorder(selected ? PerryTheme.Colors.accent : PerryTheme.Colors.icon, lineWidth: 1.5)
            .frame(width: 15, height: 15)
            .overlay {
                if selected {
                    Circle().fill(PerryTheme.Colors.accent).frame(width: 7, height: 7)
                }
            }
            .accessibilityHidden(true)
    }
}

struct ReturnHint: View {
    var body: some View {
        Image(systemName: "return")
            .font(PerryTheme.Scale.body.weight(.semibold))
            .imageScale(.small)
            .opacity(0.55)
            .accessibilityHidden(true)
    }
}

@MainActor
enum AppIcons {
    private static var cache: [String: NSImage?] = [:]

    static func installed(bundleID: String) -> NSImage? {
        if let cached = cache[bundleID] { return cached }
        let image = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[bundleID] = image
        return image
    }
}

enum BrandCatalog {
    struct Entry {
        let bundleIDs: [String]
        let asset: String?
        let tile: Tile
    }

    enum Tile {
        case native
        case rounded
        case dark
        case light
    }

    static let entries: [String: Entry] = [
        "notion": Entry(bundleIDs: ["notion.id"], asset: "brand-notion", tile: .native),
        "slack": Entry(bundleIDs: ["com.tinyspeck.slackmacgap"], asset: "brand-slack", tile: .light),
        "linear": Entry(bundleIDs: ["com.linear"], asset: "brand-linear", tile: .rounded),
        "github": Entry(bundleIDs: ["com.github.GitHubClient"], asset: "brand-github", tile: .dark),
        "google-drive": Entry(bundleIDs: ["com.google.drivefs"], asset: "brand-google-drive", tile: .native),
        "google-calendar": Entry(bundleIDs: [], asset: "brand-google-calendar", tile: .native),
        "google-gmail": Entry(bundleIDs: [], asset: "brand-google-gmail", tile: .native),
        "microsoft": Entry(bundleIDs: ["com.microsoft.Outlook"], asset: "brand-microsoft", tile: .native),
        "apple-calendar": Entry(bundleIDs: ["com.apple.iCal"], asset: nil, tile: .native),
    ]
}

struct BrandMark: View {
    let id: String
    var name: String?
    var bundleID: String?
    var size = PerryTheme.Icon.slot

    private var entry: BrandCatalog.Entry? { BrandCatalog.entries[id] }

    var body: some View {
        mark
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var mark: some View {
        if let image = installedIcon {
            Image(nsImage: image).resizable().scaledToFit()
        } else if let asset = entry?.asset {
            bundled(asset)
        } else {
            monogram
        }
    }

    private var installedIcon: NSImage? {
        ((entry?.bundleIDs ?? []) + [bundleID].compactMap { $0 }).lazy
            .compactMap { AppIcons.installed(bundleID: $0) }
            .first
    }

    @ViewBuilder
    private func bundled(_ asset: String) -> some View {
        switch entry?.tile ?? .native {
        case .native:
            Image(asset).resizable().scaledToFit()
        case .rounded:
            Image(asset).resizable().scaledToFit().clipShape(shape)
        case .dark:
            ZStack {
                shape.fill(Color.black)
                Image(asset).resizable().scaledToFit().padding(size * 0.2)
            }
        case .light:
            ZStack {
                shape.fill(Color.white)
                Image(asset).resizable().scaledToFit().padding(size * 0.2)
            }
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
    }

    private var monogram: some View {
        Text(String((name ?? id).prefix(1)).uppercased())
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(PerryTheme.Colors.text)
            .frame(width: size, height: size)
            .background(PerryTheme.Colors.chip, in: shape)
    }
}
