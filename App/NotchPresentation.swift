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
        let title: String?
        let content: AnyView
        let onDismiss: (() -> Void)?
        let preservesWorkspace: Bool
        var contentHeight: CGFloat?
    }

    static let shared = NotchPresentation()
    @Published private(set) var entries: [Entry] = []
    @Published var showsInteraction = true
    private var asking: [UUID: () -> Void] = [:]
    var onPresent: ((Priority) -> Void)?
    var frame: NSRect = .zero

    var current: Entry? {
        entries.enumerated().max {
            ($0.element.priority.rawValue, $0.offset) < ($1.element.priority.rawValue, $1.offset)
        }?.element
    }

    func present<Content: View>(id: UUID, priority: Priority, title: String? = nil, content: Content, reveal: Bool = true, preservesWorkspace: Bool = false, onDismiss: (() -> Void)? = nil) {
        let height = entries.first { $0.id == id }?.contentHeight
        entries = entries.filter { $0.id != id } + [Entry(id: id, priority: priority, title: title, content: AnyView(content), onDismiss: onDismiss, preservesWorkspace: preservesWorkspace, contentHeight: height)]
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

    func ask<Answer, Content: View>(
        id: UUID = UUID(),
        priority: Priority,
        title: String? = nil,
        cancelled: Answer,
        content: (_ answer: @escaping (Answer) -> Void) -> Content
    ) async -> Answer {
        let pending = PendingAnswer<Answer>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Answer, Never>) in
                guard !Task.isCancelled else {
                    continuation.resume(returning: cancelled)
                    return
                }
                pending.continuation = continuation
                let finish: (Answer) -> Void = { [weak self] answer in
                    guard pending.continuation != nil else { return }
                    self?.asking[id] = nil
                    self?.remove(id)
                    pending.resolve(answer)
                }
                asking[id] = { finish(cancelled) }
                present(id: id, priority: priority, title: title, content: content(finish), onDismiss: { finish(cancelled) })
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelAsk(id) }
        }
    }

    func cancelAsk(_ id: UUID) {
        asking[id]?()
    }
}

@MainActor
private final class PendingAnswer<Answer> {
    var continuation: CheckedContinuation<Answer, Never>?

    func resolve(_ answer: Answer) {
        continuation?.resume(returning: answer)
        continuation = nil
    }
}

final class FirstClickPopUpButton: NSPopUpButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct NotchCommandsMenu: NSViewRepresentable {
    let controller: AppController

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = FirstClickPopUpButton(frame: .zero, pullsDown: true)
        button.bezelStyle = .inline
        button.isBordered = false
        button.imagePosition = .imageOnly
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        button.contentTintColor = PerryTheme.Colors.iconNS
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
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        menu.insertItem(face, at: 0)
        return menu
    }
}
