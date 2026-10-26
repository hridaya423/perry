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
enum PerryLauncher {
    static func main() {
        if let output = PermissionCheck.output(for: CommandLine.arguments) {
            print(output)
            exit(0)
        }
        PerryApp.main()
    }
}

struct PerryApp: App {
    @NSApplicationDelegateAdaptor(AppController.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Talk to Perry…") { appDelegate.showPanel() }
                Divider()
                Button("Settings…") { appDelegate.openSettings(.general) }
                    .keyboardShortcut(",", modifiers: .command)
                Button("Set up Perry…") { appDelegate.runOnboarding(force: true) }
            }
        }
    }
}
