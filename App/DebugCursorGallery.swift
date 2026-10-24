#if DEBUG
import AppKit
import SwiftUI
import PerryOverlay

final class DebugCursorGalleryWindow: NSWindow {
    static func show() {
        let window = DebugCursorGalleryWindow()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        title = "Perry moods"
        contentView = NSHostingView(rootView: DebugCursorGallery())
    }
}

private struct DebugCursorGallery: View {
    private let backgrounds: [AnyShapeStyle] = [
        AnyShapeStyle(Color(white: 0.97)),
        AnyShapeStyle(Color(red: 0.05, green: 0.05, blue: 0.06)),
        AnyShapeStyle(LinearGradient(colors: [.blue, .orange], startPoint: .top, endPoint: .bottom)),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(backgrounds.indices, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(PerryMood.allCases, id: \.self) { mood in
                        ZStack {
                            Rectangle().fill(backgrounds[row])
                            PerryCharacter(mood: mood, micLevel: 0.5, size: 48)
                        }
                        .frame(width: 136, height: 120)
                    }
                }
            }
            HStack(spacing: 0) {
                ForEach(PerryMood.allCases, id: \.self) { mood in
                    Text(mood.rawValue).font(.caption).frame(width: 136, height: 24)
                }
            }
        }
    }
}
#endif
