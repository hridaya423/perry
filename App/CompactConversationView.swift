import AppKit
import Combine
import SwiftUI
import PerryBrain
import PerryOverlay

final class CompactConversationPanel: NSPanel {
    static let identifier = NSUserInterfaceItemIdentifier("perry.session")

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

extension EnvironmentValues {
    @Entry var notchMood: PerryMood = .resting
    @Entry var notchCameraInset: CGFloat = 24
}

struct CompactConversationView: View {
    @ObservedObject var controller: AppController
    @ObservedObject private var model: HomeModel
    @ObservedObject private var presentation = NotchPresentation.shared
    @ObservedObject private var expansion: NotchExpansion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var metrics: NotchLayout.Metrics
    @State private var mood: PerryMood = .resting

    init(controller: AppController) {
        self.controller = controller
        self.model = controller.homeController.homeModel
        self.expansion = controller.sessionPanel.expansion
        _metrics = State(initialValue: NotchLayout.Metrics(controller.sessionPanel.screen ?? NotchPresence.screenUnderPointer()))
    }

    private var cameraInset: CGFloat { metrics.cameraInset }

    private var size: CGSize {
        NotchLayout.size(NotchLayout.mode(presentation, expansion: expansion), cameraInset: cameraInset, screen: metrics.screen)
    }

    private var grown: Bool { expansion.open || reduceMotion }
    private var shape: NotchShape { grown ? .open : .closed }
    private var shapeSize: CGSize { grown ? size : metrics.closed }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: cameraInset)
                .overlay { crown }
                .overlay {
                    if let onboarding = model.onboarding, model.sidebarSelection != .settings {
                        OnboardingCrown(director: onboarding)
                    }
                }
            NotchInteractionHost(presentation: presentation) {
                workspace
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if presentation.current != nil, !presentation.showsInteraction, !peeking {
                HStack {
                    Spacer()
                    Button("Back to task", systemImage: "arrow.up.right") {
                        presentation.showsInteraction = true
                        controller.showPanel()
                    }.buttonStyle(.borderless)
                }
                .font(PerryTheme.Scale.secondary)
                .padding(.top, 8)
            }
        }
        .padding(.horizontal, NotchShape.open.topRadius)
        .padding(.bottom, NotchLayout.bottomInset)
        .opacity(expansion.contentShown ? 1 : 0)
        .offset(y: expansion.contentShown || reduceMotion ? 0 : -8)
        .frame(width: size.width, height: size.height)
        .mask(alignment: .top) { shape.frame(width: shapeSize.width, height: shapeSize.height) }
        .background(alignment: .top) {
            shape.surface(crown: cameraInset + 8, lifted: expansion.open)
                .frame(width: shapeSize.width, height: shapeSize.height)
        }
        .opacity(reduceMotion && !expansion.open ? 0 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? NotchMotion.reducedResize : NotchMotion.resize, value: size)
        .foregroundStyle(PerryTheme.Colors.text)
        .tint(PerryTheme.Colors.accent)
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
        .environment(\.notchMood, mood)
        .environment(\.notchCameraInset, cameraInset)
        .environment(\.perryCharacterPaused, !expansion.contentShown)
        .onReceive(controller.overlayState.$voiceState.combineLatest(controller.overlayState.$buddyState)
            .map(PerryMood.init).removeDuplicates()) { mood = $0 }
        .onAppear { updateCameraInset() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in updateCameraInset() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification)) { _ in updateCameraInset() }
        .onChange(of: model.sidebarSelection) { _, _ in
            expansion.peeking = false
            controller.refreshNotchLayout()
        }
        .onChange(of: expansion.peeking) { _, _ in controller.refreshNotchLayout() }
        .onChange(of: expansion.peekHeight) { _, _ in controller.refreshNotchLayout() }
        .onChange(of: presentation.current?.id) { _, _ in controller.refreshNotchLayout() }
        .task(id: presentation.current?.contentHeight) { controller.refreshNotchLayout() }
    }

    @ViewBuilder
    private var workspace: some View {
        if model.sidebarSelection == .settings {
            NotchWorkspaceView(model: model)
        } else if let onboarding = model.onboarding {
            OnboardingNotchView(director: onboarding, model: model)
        } else if peeking {
            NotchPeekView(model: model, presentation: presentation, onOpen: open, onExpand: controller.showPanel)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    var transaction = Transaction()
                    transaction.disablesAnimations = expansion.peekHeight == nil
                    withTransaction(transaction) { expansion.peekHeight = height }
                }
                .padding(.top, NotchLayout.topInset)
                .frame(maxHeight: .infinity, alignment: .top)
        } else {
            NotchWorkspaceView(model: model)
        }
    }

    private var peeking: Bool {
        expansion.peeking && model.sidebarSelection != .settings && model.onboarding == nil
    }

    @ViewBuilder
    private var crown: some View {
        if peeking {
            EmptyView()
        } else if presentation.current != nil, presentation.showsInteraction {
            HStack {
                Button(action: controller.showWorkspace) {
                    Label("Back", systemImage: "chevron.left").imageScale(.small)
                        .font(PerryTheme.Scale.chip)
                        .padding(.horizontal, 6)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(PerryTheme.Colors.textSecondary)
                Spacer()
                WindowControlButton(systemImage: "chevron.up", label: "Collapse", action: controller.collapseNotch)
            }
        }
    }

    private func open(_ row: PeekRow) {
        switch row.kind {
        case .needsYou: presentation.showsInteraction = true
        case .setup: return controller.runOnboarding(force: false)
        case .task: model.sidebarSelection = UUID(uuidString: row.id).map { .thread($0) } ?? .history
        case .perry: model.sidebarSelection = .perryEditor(UUID(uuidString: row.id))
        case .suggestion: model.sidebarSelection = .suggestions
        }
        controller.showPanel()
    }

    private func updateCameraInset() {
        metrics = NotchLayout.Metrics(controller.sessionPanel.screen ?? NotchPresence.screenUnderPointer())
    }
}

struct CompactTargetChooser: View {
    var onSelect: (CuaTargetHint?) -> Void
    @State private var targets: [CuaTargetHint] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose an app or window").font(PerryTheme.Scale.rowTitle)
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
                                Text(item.windowID == nil ? "Application" : Self.applicationName(item)).font(PerryTheme.Scale.secondary).foregroundStyle(.secondary)
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
        .frame(maxWidth: 420, alignment: .leading)
        .onAppear { targets = EnvironmentProbe.availableTargets() }
    }

    static func bundleID(_ target: CuaTargetHint) -> String? {
        target.bundleID ?? target.processID.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
    }

    static func applicationName(_ target: CuaTargetHint) -> String {
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
    @ViewBuilder var workspace: () -> Workspace
    @State private var viewport: CGFloat = 0

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
                ScrollView {
                    entry.content
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            var transaction = Transaction()
                            transaction.disablesAnimations = entry.contentHeight == nil
                            withTransaction(transaction) { presentation.measure(entry.id, height: height) }
                        }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewport = $0 }
                .mask {
                    VStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.white, (entry.contentHeight ?? 0) > viewport + 1 ? .clear : .white],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: 16)
                    }
                }
                .padding(.top, NotchLayout.topInset)
                .padding(.horizontal, NotchLayout.contentInset)
            }
        }
    }
}
