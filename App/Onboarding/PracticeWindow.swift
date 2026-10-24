import AppKit
import PerryOverlay
import SwiftUI

/// Bundled practice surface for onboarding (§4.1.5): a real window with fake
/// controls, three real files in Perry's private sandbox, and a text box —
/// so the "point / guide / rename-and-undo / dictate" beats exercise the real
/// pipelines (AX, dictation, file ops, undo) without touching anything the
/// user cares about. The voice-driven rename needs the Do pipeline (Phase 7);
/// until then the same real file ops run from buttons.
@MainActor
final class PracticeWindow: NSObject, NSWindowDelegate {
    enum Event {
        /// Rename was performed and then undone — the renameUndo beat's
        /// completion condition.
        case renamedAndUndone
        /// Text landed in the practice text box (dictated or typed).
        case dictated
    }

    var onEvent: ((Event) -> Void)?
    var onClose: (() -> Void)?

    private(set) var window: NSWindow?
    private let state = PracticeState()
    private var renamedNames: [String] = []
    private var dictatedFired = false

    static var sandboxDirectory: URL {
        (AppController.supportDirectory ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("PracticeSandbox", isDirectory: true)
    }

    func show() {
        seedSandbox()
        if window == nil {
            window = makeWindow()
        }
        refreshFileList()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
    }

    // MARK: Sandbox file ops (real moves, so undo is real too)

    private func seedSandbox() {
        let dir = Self.sandboxDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in Self.seedNames {
            let url = dir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) {
                try? "Practice file — safe to rename or delete.".write(
                    to: url, atomically: true, encoding: .utf8
                )
            }
        }
    }

    private static let seedNames = ["Trip notes.txt", "Quarterly numbers.txt", "Cover draft.txt"]

    private func refreshFileList() {
        let names = (try? FileManager.default.contentsOfDirectory(
            at: Self.sandboxDirectory,
            includingPropertiesForKeys: nil
        ))?.map(\.lastPathComponent).sorted() ?? []
        state.files = names
    }

    func performRename() {
        let dir = Self.sandboxDirectory
        renamedNames = []
        for name in Self.seedNames {
            let from = dir.appendingPathComponent(name)
            let to = dir.appendingPathComponent("Perry — \(name)")
            if FileManager.default.fileExists(atPath: from.path) {
                try? FileManager.default.moveItem(at: from, to: to)
                renamedNames.append(name)
            }
        }
        refreshFileList()
    }

    func performUndo() {
        let dir = Self.sandboxDirectory
        for name in renamedNames {
            let from = dir.appendingPathComponent("Perry — \(name)")
            let to = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: from.path) {
                try? FileManager.default.moveItem(at: from, to: to)
            }
        }
        let didUndo = !renamedNames.isEmpty
        renamedNames = []
        refreshFileList()
        if didUndo {
            onEvent?(.renamedAndUndone)
        }
    }

    fileprivate func noteDictation() {
        guard !dictatedFired else { return }
        dictatedFired = true
        onEvent?(.dictated)
    }

    // MARK: Window

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingView(rootView: PracticeWindowView(state: state, window: self))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 330),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Perry Practice"
        window.contentView = hosting
        window.delegate = self
        window.center()
        window.isReleasedWhenClosed = false
        PerryWindowChrome.applyChrome(to: window)
        return window
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        onClose?()
    }
}

/// Observable state for the practice surface — file names mirror the real
/// sandbox directory after each op.
@MainActor
private final class PracticeState: ObservableObject {
    @Published var files: [String] = []
    @Published var draftText = ""
}

private struct PracticeWindowView: View {
    @ObservedObject var state: PracticeState
    let window: PracticeWindow

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Files").font(.headline)
                ForEach(state.files, id: \.self) { name in
                    Label(name, systemImage: "doc")
                        .font(.callout)
                        .accessibilityLabel("File \(name)")
                }
                Spacer()
                HStack {
                    Button("Rename these three files") { window.performRename() }
                    Button("Undo rename") { window.performUndo() }
                }
                .controlSize(.small)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Toggle("Sync drafts", isOn: .constant(true))
                    .accessibilityLabel("Sync drafts toggle")
                Button("Save draft") {}
                    .accessibilityLabel("Save draft button")
                Text("Notes").font(.headline)
                TextEditor(text: $state.draftText)
                    .font(.callout)
                    .border(.quaternary)
                    .accessibilityLabel("Notes text box")
                    .onChange(of: state.draftText) { _, newValue in
                        if !newValue.isEmpty { window.noteDictation() }
                    }
                Text("A safe practice space. The files are real; the rest is fake.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 460, minHeight: 330)
    }
}
