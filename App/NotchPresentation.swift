import AppKit
import SwiftUI

@MainActor
final class NotchPresentation: ObservableObject {
    enum Priority: Int {
        case activity, voice, guide, routine, approval
    }

    struct Entry: Identifiable {
        let id: UUID
        let priority: Priority
        let content: AnyView
        let onDismiss: (() -> Void)?
        let preservesWorkspace: Bool
        var contentHeight: CGFloat?
    }

    static let shared = NotchPresentation()
    @Published private(set) var entries: [Entry] = []
    @Published var showsInteraction = true
    var onPresent: ((Priority) -> Void)?
    var frame: NSRect = .zero

    var current: Entry? {
        entries.enumerated().max {
            ($0.element.priority.rawValue, $0.offset) < ($1.element.priority.rawValue, $1.offset)
        }?.element
    }

    func present<Content: View>(id: UUID, priority: Priority, content: Content, reveal: Bool = true, preservesWorkspace: Bool = false, onDismiss: (() -> Void)? = nil) {
        let height = entries.first { $0.id == id }?.contentHeight
        entries = entries.filter { $0.id != id } + [Entry(id: id, priority: priority, content: AnyView(content), onDismiss: onDismiss, preservesWorkspace: preservesWorkspace, contentHeight: height)]
        if reveal {
            showsInteraction = true
            onPresent?(priority)
        }
    }

    func measure(_ id: UUID, height: CGFloat) {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              height.isFinite, height > 0,
              entries[index].contentHeight != height else { return }
        entries[index].contentHeight = height
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
    }

    func dismissCurrent() {
        guard showsInteraction else { return }
        current?.onDismiss?()
    }

    func contains(_ id: UUID) -> Bool {
        entries.contains { $0.id == id }
    }
}

struct NotchCommandsMenu: NSViewRepresentable {
    let controller: AppController

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.bezelStyle = .inline
        button.isBordered = false
        button.imagePosition = .imageOnly
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        button.contentTintColor = .secondaryLabelColor
        button.menu = Self.menu(for: controller)
        button.setAccessibilityLabel("More Perry controls")
        return button
    }

    func updateNSView(_ nsView: NSPopUpButton, context: Context) {
        nsView.menu = Self.menu(for: controller)
    }

    private static func menu(for controller: AppController) -> NSMenu {
        let menu = controller.buildMenu()
        let face = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        face.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        menu.insertItem(face, at: 0)
        return menu
    }
}
