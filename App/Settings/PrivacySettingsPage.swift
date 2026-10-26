import AppKit
import PerryCapture
import PerryCore
import PerryGuide
import SwiftUI

struct PrivacySettingsPage: View {
    let controller: AppController
    @State private var permissions: PerryPermissionSnapshot?
    @State private var showReportProblem = false
    @AppStorage(PerryPreferences.$workspaceRoot.key) private var workspaceRoot: String?
    @AppStorage(PerryPreferences.$hidePersonalDetails.key) private var hidePersonalDetails = false

    var body: some View {
        SettingsScroll {
            SettingsCard(title: "Permissions", footer: "Turning on Screen Recording may ask you to quit and reopen Perry.") {
                permissionRow(.accessibility, why: "Lets Perry read and act on whatever you point at.", granted: permissions?.accessibility)
                SettingsDivider()
                permissionRow(.screenRecording, why: "Lets Perry see what’s in your windows so answers match your screen.", granted: permissions?.screenRecording.isUsable)
                SettingsDivider()
                permissionRow(.microphone, why: "Lets Perry hear you for talk and dictation.", granted: permissions?.microphone.isUsable)
                SettingsDivider()
                permissionRow(.inputMonitoring, why: "Lets Perry notice the dictation key when another app is in front.", granted: permissions?.inputMonitoring)
            }
            SettingsCard(title: "Cloud brains", footer: "Screenshots are sent as they are. Brains on this Mac always see the real details.") {
                Toggle(isOn: $hidePersonalDetails) {
                    Text("Hide personal details")
                    Text("Before a message leaves this Mac, Perry swaps names, emails, phone numbers, card numbers, addresses and keys for placeholders. Perry puts the real details back in the reply.").settingNote()
                }
                .settingsRowPadding()
            }
            SettingsCard(title: "Work folder", footer: "File tasks stay inside this folder.") {
                SettingsRow(title: WorkspaceScope.root.lastPathComponent, detail: (WorkspaceScope.root.path as NSString).abbreviatingWithTildeInPath) {
                    Button("Choose…", action: chooseWorkspace)
                }
            }
            SettingsCard(title: "Always blocked", footer: "Perry never looks at or acts in these apps. Banking, sign-in, payment and checkout windows are refused the same way, in any app.") {
                ForEach(Array(Self.blockedApps.enumerated()), id: \.element.bundleID) { index, app in
                    if index > 0 { SettingsDivider() }
                    HStack(spacing: 10) {
                        BrandMark(id: app.bundleID, name: app.name, bundleID: app.bundleID, size: 20)
                        Text(app.name)
                            .font(PerryTheme.Scale.body)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .help(app.bundleID)
                    .accessibilityElement(children: .combine)
                }
            }
            SettingsCard(title: "Export and report") {
                SettingsRow(title: "Activity log") {
                    Button("Export…") { controller.exportActivityLog() }
                }
                SettingsDivider()
                SettingsRow(title: "Diagnostics", detail: "Setup and permission details only, never your messages, files, transcripts or memories.") {
                    Button("Export…") { controller.exportDiagnostics() }
                }
                SettingsDivider()
                SettingsRow(title: "Report a problem") {
                    Button("Report…") { showReportProblem = true }
                }
            }
            SettingsCard {
                SettingsRow(title: "Erase all Perry data", detail: "Deletes tasks, history, memory, approvals, preferences, saved sign-ins and temporary files.") {
                    Button("Erase all…", role: .destructive) {
                        NotificationCenter.default.post(name: .perryWipeDataRequested, object: nil)
                    }
                }
            }
        }
        .task { permissions = await PerryPermissionSnapshot.probe() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { permissions = await PerryPermissionSnapshot.probe() }
        }
        .notchDialog(
            "Report a problem",
            isPresented: $showReportProblem,
            message: "Export the diagnostics file, then attach it to a new issue on GitHub. Perry doesn’t upload anything."
        ) {
            var actions = [NotchDialog.Action("Export diagnostics") { controller.exportDiagnostics() }]
            if let url = Self.issuesURL {
                actions.append(NotchDialog.Action("Open GitHub") { NSWorkspace.shared.open(url) })
            }
            return actions
        }
    }

    private func permissionRow(_ pane: PrivacyPane, why: String, granted: Bool?) -> some View {
        let name = pane == .microphone ? "Microphone" : pane.displayName()
        return SettingsRow(title: name, detail: why) {
            switch granted {
            case .some(true):
                StatusMark(.ok)
                    .accessibilityLabel("\(name) permission granted")
            case .some(false):
                Button("Turn on…") { fix(pane) }
                    .accessibilityLabel("Turn on \(name) permission")
            case nil:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Checking \(name) permission")
            }
        }
    }

    private func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = WorkspaceScope.root
        panel.prompt = "Use as work folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        WorkspaceScope.setRoot(url)
    }

    private func fix(_ pane: PrivacyPane) {
        Task {
            if pane == .microphone {
                _ = await PerryPermissionProbe.requestMicrophone()
                pane.open()
            } else {
                await PermissionGuideCoordinator.guide(pane)
            }
        }
    }

    private static var issuesURL: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "PerryIssuesURL") as? String,
              !raw.isEmpty,
              !raw.hasPrefix("$(") else { return nil }
        return URL(string: raw)
    }

    private static let blockedApps = TrustGuard.defaultBlockedBundleIDs.sorted().map { bundleID in
        let names = [
            "com.agilebits.onepassword-osx": "1Password",
            "com.agilebits.onepassword7": "1Password 7",
            "com.apple.KeychainAccess": "Keychain Access",
            "com.bitwarden.desktop": "Bitwarden",
            "com.dashlane.dashlanephonehome": "Dashlane",
            "com.keepersecurity.KeeperDesktop": "Keeper",
            "com.lastpass.LastPass": "LastPass",
        ]
        return (bundleID: bundleID, name: names[bundleID] ?? bundleID)
    }
}
