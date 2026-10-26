import AppKit
import PerryCapture
import PerryCore
import PerryGuide
import SwiftUI

struct PrivacySettingsPage: View {
    let controller: AppController
    @State private var permissions: PerryPermissionSnapshot?
    @State private var showReportProblem = false

    var body: some View {
        SettingsScroll {
            SettingsCard(title: "Permissions", footer: "Turning on Screen Recording may ask you to quit and reopen Perry.") {
                permissionRow(.accessibility, why: "Lets Perry read and act on whatever you point at.", granted: permissions?.accessibility)
                SettingsDivider()
                permissionRow(.screenRecording, why: "Lets Perry see window contents so answers stay grounded.", granted: permissions?.screenRecording.isUsable)
                SettingsDivider()
                permissionRow(.microphone, why: "Lets Perry hear you for talk and dictation.", granted: permissions?.microphone.isUsable)
                SettingsDivider()
                permissionRow(.inputMonitoring, why: "Lets Perry hear the dictation key while other apps are focused.", granted: permissions?.inputMonitoring)
            }
            SettingsCard(title: "Always blocked", footer: "Perry never looks at or acts in these apps. Banking, sign-in, payment and checkout windows are refused the same way, in any app.") {
                ForEach(Array(Self.blockedApps.enumerated()), id: \.element.bundleID) { index, app in
                    if index > 0 { SettingsDivider() }
                    HStack(spacing: 10) {
                        Group {
                            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
                            } else {
                                Image(systemName: "lock.fill")
                                    .font(PerryTheme.Icon.inline)
                                    .foregroundStyle(PerryTheme.Colors.textSecondary)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .background(PerryTheme.Colors.chip, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            }
                        }
                        .frame(width: 20, height: 20)
                        .accessibilityHidden(true)
                        Text(app.name)
                            .font(PerryTheme.Scale.body)
                        Spacer()
                        Text("Never")
                            .settingNote()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .help(app.bundleID)
                    .accessibilityElement(children: .combine)
                }
            }
            SettingsCard(title: "Records") {
                SettingsRow(title: "Activity log") {
                    Button("Export…") { controller.exportActivityLog() }
                }
                SettingsDivider()
                SettingsRow(title: "Diagnostics", detail: "Setup and permission details only, never your requests, files, transcripts or memories.") {
                    Button("Export…") { controller.exportDiagnostics() }
                }
                SettingsDivider()
                SettingsRow(title: "Something wrong?") {
                    Button("Report a problem…") { showReportProblem = true }
                }
            }
            SettingsCard {
                SettingsRow(title: "Erase all Perry data", detail: "Tasks, history, memory, approvals, preferences, credentials and temporary files. Perry asks you to confirm first.") {
                    Button("Erase…", role: .destructive) {
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
            message: "Perry never uploads anything automatically. Export the redacted diagnostics file, then attach it to a new issue in Perry’s GitHub repository."
        ) {
            var actions = [NotchDialog.Action("Export diagnostics first") { controller.exportDiagnostics() }]
            if let url = Self.issuesURL {
                actions.append(NotchDialog.Action("Open GitHub issues") { NSWorkspace.shared.open(url) })
            }
            return actions
        }
    }

    private func permissionRow(_ pane: PrivacyPane, why: String, granted: Bool?) -> some View {
        let name = pane == .microphone ? "Microphone" : pane.displayName()
        return SettingsRow(title: name, detail: why) {
            switch granted {
            case .some(true):
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(PerryTheme.Colors.success)
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
