import Foundation
import SwiftUI

@MainActor
final class NotchDialog {
    struct Action {
        let title: String
        let role: ButtonRole?
        let perform: () -> Void

        init(_ title: String, role: ButtonRole? = nil, perform: @escaping () -> Void) {
            self.title = title
            self.role = role
            self.perform = perform
        }
    }

    let id: UUID
    private let title: String
    private let message: String?
    private let cancelTitle: String
    private let actions: [Action]
    private let priority: NotchPresentation.Priority
    private let presentation: NotchPresentation
    private let clearSource: () -> Void
    private var resolved = false

    init(title: String, message: String? = nil, cancelTitle: String = "Cancel",
         actions: [Action], id: UUID = UUID(),
         priority: NotchPresentation.Priority = .approval,
         presentation: NotchPresentation = .shared,
         onClearSource: @escaping () -> Void = {}) {
        self.title = title
        self.message = message
        self.cancelTitle = cancelTitle
        self.actions = actions
        self.id = id
        self.priority = priority
        self.presentation = presentation
        self.clearSource = onClearSource
    }

    convenience init?<Item>(title: String, message: String? = nil, cancelTitle: String = "Cancel",
                            item: Item?, actions: (Item) -> [Action], id: UUID = UUID(),
                            presentation: NotchPresentation = .shared,
                            onClearSource: @escaping () -> Void = {}) {
        guard let item else { return nil }
        self.init(title: title, message: message, cancelTitle: cancelTitle,
                  actions: actions(item), id: id, presentation: presentation, onClearSource: onClearSource)
    }

    func present() {
        guard !resolved else { return }
        presentation.present(
            id: id,
            priority: priority,
            content: NotchDialogView(
                title: title,
                message: message,
                cancelTitle: cancelTitle,
                actions: actions.enumerated().map { index, action in
                    Action(action.title, role: action.role) { [self] in select(index) }
                },
                onCancel: { [self] in cancel() }),
            preservesWorkspace: true,
            onDismiss: { [self] in cancel() })
    }

    func select(_ index: Int) {
        guard actions.indices.contains(index) else { return }
        finish(actions[index].perform)
    }

    func cancel() {
        finish(nil)
    }

    private func finish(_ perform: (() -> Void)?) {
        guard !resolved else { return }
        resolved = true
        presentation.remove(id)
        perform?()
        clearSource()
    }
}

struct NotchDialogView: View {
    let title: String
    let message: String?
    let cancelTitle: String
    let actions: [NotchDialog.Action]
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PerryTheme.Spacing.section) {
            Text(title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let message, !message.isEmpty {
                Text(message)
                    .font(PerryTheme.Scale.secondary.weight(.medium))
                    .foregroundStyle(PerryTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if actions.count > 1 {
                actionRows
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .bottom, spacing: 8) {
                        Spacer(minLength: PerryTheme.Spacing.control)
                        cancelButton
                        ForEach(actions.indices, id: \.self) { index in
                            actionButton(index, expanded: false)
                        }
                    }
                    actionRows
                }
            }
        }
        .controlSize(.small)
        .background { returnToCancel }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(PerryTheme.Colors.text)
        .tint(PerryTheme.Colors.accent)
    }

    private var actionRows: some View {
        VStack(alignment: .leading, spacing: PerryTheme.Spacing.inline) {
            ForEach(actions.indices, id: \.self) { index in
                actionButton(index, expanded: true)
            }
            cancelButton(expanded: true)
        }
    }

    private var cancelButton: some View {
        cancelButton(expanded: false)
    }

    private func cancelButton(expanded: Bool) -> some View {
        Button(role: .cancel, action: onCancel) {
            Text(cancelTitle)
                .frame(maxWidth: expanded ? .infinity : nil)
        }
        .buttonStyle(InkButtonStyle(actions.isEmpty ? .primary : .secondary))
        .keyboardShortcut(.cancelAction)
    }

    private var returnToCancel: some View {
        Button(cancelTitle, action: onCancel)
            .keyboardShortcut(.defaultAction)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func actionButton(_ index: Int, expanded: Bool) -> some View {
        let action = actions[index]
        let button = Button(role: action.role) {
            action.perform()
        } label: {
            Text(action.title)
                .frame(maxWidth: expanded ? .infinity : nil)
        }
        button.buttonStyle(InkButtonStyle(action.role == .destructive ? .destructive : index == 0 ? .primary : .secondary))
    }
}

private struct NotchDialogModifier: ViewModifier {
    let presented: Bool
    let makeDialog: () -> NotchDialog?
    @State private var active: NotchDialog?

    func body(content: Content) -> some View {
        content.onChange(of: presented) { _, shown in
            if shown, let dialog = makeDialog() {
                active = dialog
                dialog.present()
            } else if !shown {
                active?.cancel()
            }
        }
    }
}

extension View {
    func notchDialog(
        _ title: String,
        isPresented: Binding<Bool>,
        message: String? = nil,
        cancelTitle: String = "Cancel",
        presentation: NotchPresentation = .shared,
        actions: @escaping () -> [NotchDialog.Action]
    ) -> some View {
        modifier(NotchDialogModifier(presented: isPresented.wrappedValue) {
            NotchDialog(
                title: title,
                message: message,
                cancelTitle: cancelTitle,
                actions: actions(),
                presentation: presentation,
                onClearSource: { isPresented.wrappedValue = false })
        })
    }

    func notchDialog<Item>(
        _ title: String,
        item: Binding<Item?>,
        message: String? = nil,
        cancelTitle: String = "Cancel",
        presentation: NotchPresentation = .shared,
        actions: @escaping (Item) -> [NotchDialog.Action]
    ) -> some View {
        modifier(NotchDialogModifier(presented: item.wrappedValue != nil) {
            NotchDialog(
                title: title,
                message: message,
                cancelTitle: cancelTitle,
                item: item.wrappedValue,
                actions: actions,
                presentation: presentation,
                onClearSource: { item.wrappedValue = nil })
        })
    }
}
