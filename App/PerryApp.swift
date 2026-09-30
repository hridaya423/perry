import SwiftUI
import PerryOverlay
import PerryGuide

#if DEBUG
enum PerryDebugTextScale: String, Equatable {
    case system
    case accessibility3

    init(arguments: [String]) {
        guard let index = arguments.firstIndex(of: "--perry-debug-text-scale"),
              arguments.indices.contains(index + 1),
              let scale = Self(rawValue: arguments[index + 1]) else {
            self = .system
            return
        }
        self = scale
    }

    @ViewBuilder
    func apply<Content: View>(to content: Content) -> some View {
        switch self {
        case .system:
            content
        case .accessibility3:
            content.dynamicTypeSize(.accessibility3)
        }
    }
}
#endif

@main
struct PerryApp: App {
    @NSApplicationDelegateAdaptor(AppController.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { appDelegate.openSettings(tab: .general) }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
