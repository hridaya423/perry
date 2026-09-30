import AppKit
import SwiftUI
import PerryBrain
import PerryOverlay

struct CompactConversationView: View {
    @ObservedObject var controller: AppController
    @ObservedObject private var model: HomeModel
    @State private var showsGuide = false
    @State private var choosesTarget = false

    init(controller: AppController) {
        self.controller = controller
        self.model = controller.homeController.homeModel
    }

    private var thread: PerryThread? {
        guard case .thread(let id) = model.sidebarSelection else { return nil }
        return model.threads.first { $0.id == id }
    }

    private var target: CuaTargetHint? {
        thread.flatMap { model.conversationTargets[$0.id] } ?? (thread == nil ? model.newConversationTarget : nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsGuide {
                Button("Back to conversation", systemImage: "arrow.left") { showsGuide = false }
                    .padding(.top, 12)
                SessionPanelView(controller: controller)
            } else {
                HStack(spacing: 12) {
                    PerryGlassCursorView(animation: .idle, size: 30, variant: .lens)
                        .accessibilityHidden(true)
                    Text("Perry").font(.system(.title3, design: .rounded, weight: .semibold))
                    Spacer()
                    Menu {
                        Button("New conversation") { model.sidebarSelection = nil }
                        ForEach(model.threads.prefix(8)) { thread in
                            Button(thread.title.isEmpty ? "Untitled conversation" : thread.title) {
                                model.sidebarSelection = .thread(thread.id)
                            }
                        }
                    } label: { Image(systemName: "clock.arrow.circlepath") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("Recent conversations")
                    Button("Open in Home", systemImage: "arrow.up.left.and.arrow.down.right") {
                        controller.dismiss()
                        controller.homeController.openHome(selection: model.sidebarSelection)
                    }
                    .labelStyle(.iconOnly)
                    .help("Open this conversation in Home")
                    Button("Close", systemImage: "xmark") { controller.dismiss() }
                        .labelStyle(.iconOnly)
                        .keyboardShortcut(.cancelAction)
                }
                .buttonStyle(.borderless)
                .padding(20)

                HStack(spacing: 8) {
                    Button {
                        choosesTarget = true
                    } label: {
                        Label(target.map(CompactTargetChooser.targetName) ?? "Choose a window", systemImage: "macwindow")
                            .lineLimit(1)
                    }
                    .help(target?.windowTitle ?? "Choose which window Perry can inspect")
                    .disabled(thread.map { model.workingThreads.contains($0.id) || model.pendingQuestions[$0.id] != nil } ?? false)
                    Spacer()
                    Button("Guide or Do") { showsGuide = true }
                        .help("Open spatial guidance and task controls")
                }
                .buttonStyle(.borderless)
                .font(.callout)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .popover(isPresented: $choosesTarget, arrowEdge: .bottom) { CompactTargetChooser(onSelect: selectTarget) }
                Divider()
                if let thread {
                    HomeConversationView(thread: thread, model: model, focusComposer: true)
                        .id(thread.id)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("What would you like help with?").font(.headline)
                            if let brain = model.deps.brain {
                                HomeConnectionView(brain: brain) {
                                    controller.homeController.openHome(selection: .settings)
                                }
                            }
                            HomeComposer(
                                text: Binding(get: { model.newConversationDraft }, set: { model.updateNewDraft($0) }),
                                placeholder: "Ask a question or describe a task…",
                                canSend: !model.isCreatingConversation,
                                focusOnAppear: true
                            ) { model.onStartConversation?(model.newConversationDraft) }
                            Text("Hold ⌃⌥ to talk while you point.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        .padding(20)
                    }
                }
                UnsavedInputRecoveryButton(model: model)
                if let error = model.storageError {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.callout).textSelection(.enabled).padding(16)
                }
            }
        }
        .frame(minWidth: PerryTheme.Sizing.panelWidth, minHeight: PerryTheme.Sizing.panelHeight)
        .background(PerryTheme.Colors.surface)
        .tint(PerryTheme.Colors.accent)
        .onAppear { consumePrompt() }
        .onChange(of: controller.pendingPromptText) { _, _ in consumePrompt() }
    }

    private func selectTarget(_ target: CuaTargetHint?) {
        if let thread { model.conversationTargets[thread.id] = target }
        else { model.newConversationTarget = target }
        choosesTarget = false
    }

    private func consumePrompt() {
        guard let text = controller.pendingPromptText else { return }
        if controller.pendingPromptDoMode {
            showsGuide = true
        } else {
            model.sidebarSelection = nil
            model.updateNewDraft(text)
            controller.pendingPromptText = nil
            showsGuide = false
        }
    }
}

private struct CompactTargetChooser: View {
    var onSelect: (CuaTargetHint?) -> Void
    @State private var targets: [CuaTargetHint] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose an app or window").font(.headline)
            if targets.isEmpty {
                Text("Open the app you want to work with, then refresh this list.")
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(targets.indices, id: \.self) { index in
                        let item = targets[index]
                        Button {
                            onSelect(item)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(Self.targetName(item)).foregroundStyle(.primary)
                                Text(item.windowID == nil ? "Application" : Self.applicationName(item)).font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .frame(height: targets.isEmpty ? 0 : 260)
            HStack {
                Button("Refresh") { targets = EnvironmentProbe.availableTargets() }
                Spacer()
                Button("No window") { onSelect(nil) }
            }
        }
        .padding(20)
        .background(PerryTheme.Colors.surface)
        .frame(width: 340)
        .onAppear { targets = EnvironmentProbe.availableTargets() }
    }

    private static func applicationName(_ target: CuaTargetHint) -> String {
        if let pid = target.processID,
           let name = NSRunningApplication(processIdentifier: pid)?.localizedName { return name }
        if let bundleID = target.bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return "Application"
    }

    static func targetName(_ target: CuaTargetHint) -> String {
        if let title = target.windowTitle, !title.isEmpty { return title }
        return applicationName(target)
    }

}
