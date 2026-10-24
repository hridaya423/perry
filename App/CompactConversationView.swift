import AppKit
import SwiftUI
import PerryBrain
import PerryOverlay

final class CompactConversationPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

struct CompactConversationView: View {
    @ObservedObject var controller: AppController
    @ObservedObject private var model: HomeModel
    @ObservedObject private var presentation = NotchPresentation.shared
    @State private var cameraInset: CGFloat = 32
    @State private var showsGuide = false

    init(controller: AppController) {
        self.controller = controller
        self.model = controller.homeController.homeModel
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.black.frame(height: cameraInset)
            NotchInteractionHost(presentation: presentation,
                                 onWorkspace: controller.showWorkspace,
                                 onCollapse: controller.collapseNotch) {
                workspace
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 16)
            if presentation.current != nil, !presentation.showsInteraction {
                HStack {
                    Spacer()
                    Button("Return to active task", systemImage: "arrow.up.right") {
                        presentation.showsInteraction = true
                        controller.showPanel()
                    }.buttonStyle(.borderless)
                }
                .font(.caption)
                .padding(.horizontal, 36)
                .padding(.bottom, 12)
            } else {
                Color.clear.frame(height: 16)
            }
        }
        .background(Color.black)
        .clipShape(NotchSilhouette())
        .foregroundStyle(PerryTheme.Colors.text)
        .tint(PerryTheme.Colors.accent)
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
        .onAppear { updateCameraInset(); consumePrompt() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in updateCameraInset() }
        .onChange(of: controller.pendingPromptText) { _, _ in consumePrompt() }
        .onChange(of: model.sidebarSelection) { _, _ in
            showsGuide = false
            controller.refreshNotchLayout()
        }
        .onChange(of: presentation.current?.id) { _, _ in controller.refreshNotchLayout() }
        .task(id: presentation.current?.contentHeight) { controller.refreshNotchLayout() }
    }

    @ViewBuilder
    private var workspace: some View {
        if model.sidebarSelection == .settings {
            NotchWorkspaceView(model: model)
        } else if let onboarding = model.onboarding {
            OnboardingNotchView(director: onboarding, model: model)
        } else if showsGuide {
            VStack(spacing: 0) {
                HStack {
                    Button("Back", systemImage: "chevron.left") { showsGuide = false }
                    Spacer()
                    Button("Close", systemImage: "xmark") {
                        showsGuide = false
                        controller.collapseNotch()
                    }
                    .labelStyle(.iconOnly)
                }.buttonStyle(.borderless).padding(20)
                SessionPanelView(controller: controller)
            }
        } else {
            NotchWorkspaceView(model: model)
        }
    }

    private func updateCameraInset() {
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main
        cameraInset = max(24, screen?.safeAreaInsets.top ?? 0)
    }

    private func consumePrompt() {
        guard let text = controller.pendingPromptText else { return }
        if controller.pendingPromptDoMode {
            showsGuide = true
        } else {
            model.sidebarSelection = nil
            model.updateNewDraft(text)
            controller.conversationVoice.cancel()
            controller.pendingPromptText = nil
            showsGuide = false
        }
    }
}

struct CompactTargetChooser: View {
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
                        .focusable()
                        .onKeyPress(keys: [.return, .space]) { _ in
                            onSelect(item)
                            return .handled
                        }
                    }
                }
            }
            .frame(height: targets.isEmpty ? 0 : 260)
            HStack {
                Button("Refresh") { targets = EnvironmentProbe.availableTargets() }
                    .focusable()
                    .onKeyPress(keys: [.return, .space]) { _ in
                        targets = EnvironmentProbe.availableTargets()
                        return .handled
                    }
                Spacer()
                Button("No window") { onSelect(nil) }
                    .focusable()
                    .onKeyPress(keys: [.return, .space]) { _ in
                        onSelect(nil)
                        return .handled
                    }
            }
        }
        .padding(20)
        .background(PerryTheme.Colors.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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

struct NotchInteractionHost<Workspace: View>: View {
    @ObservedObject var presentation: NotchPresentation
    let onWorkspace: () -> Void
    let onCollapse: () -> Void
    @ViewBuilder var workspace: () -> Workspace

    private var showsInteraction: Bool {
        presentation.current != nil && presentation.showsInteraction
    }

    var body: some View {
        ZStack {
            if !showsInteraction || presentation.current?.preservesWorkspace == true {
                workspace()
                    .frame(width: showsInteraction ? 0 : nil,
                           height: showsInteraction ? 0 : nil)
                    .clipped()
                    .opacity(showsInteraction ? 0 : 1)
                    .allowsHitTesting(!showsInteraction)
                    .accessibilityHidden(showsInteraction)
                    .disabled(showsInteraction)
            }
            if let entry = presentation.current, presentation.showsInteraction {
                VStack(spacing: 16) {
                    HStack {
                        Button("Workspace", systemImage: "chevron.left") { onWorkspace() }
                            .buttonStyle(.borderless)
                        Spacer()
                        Button("Collapse", systemImage: "chevron.up") { onCollapse() }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                    }
                    ScrollView {
                        entry.content
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .fixedSize(horizontal: false, vertical: true)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                                presentation.measure(entry.id, height: height)
                            }
                    }
                }.padding(24)
            }
        }
    }
}
