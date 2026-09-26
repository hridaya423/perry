import AppKit

/// Content for the hover peek. Everything is pre-formatted strings — the
/// view never queries models, so it stays trivially refreshable.
struct HomePeekContent: Equatable {
    var agentLines: [String] = []
    var unreadCount = 0
    var pinnedPerryNames: [String] = []
    var lastAnswer: String?

    var isEmpty: Bool {
        agentLines.isEmpty && unreadCount == 0 && pinnedPerryNames.isEmpty
            && (lastAnswer?.isEmpty ?? true)
    }
}

/// The notch peek: a compact AppKit column under the resting strip.
/// AppKit, not NSHostingView — a hosting view in a borderless panel can
/// re-invalidate window size extrema every constraint pass (see
/// NotchStatusController's header note).
@MainActor
final class HomePeekView: NSView {
    var onOpenHome: (() -> Void)?

    private let stack = NSStackView()
    private var content = HomePeekContent()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 240)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(_ content: HomePeekContent) {
        self.content = content
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }

        addHeading("Perry")
        if content.isEmpty {
            addRow("Nothing new — hover anytime.", color: .secondaryLabelColor)
        } else {
            for line in content.agentLines { addRow("● \(line)", color: .labelColor) }
            if content.unreadCount > 0 {
                addRow(content.unreadCount == 1 ? "1 unread result" : "\(content.unreadCount) unread results",
                       color: .systemMint)
            }
            for name in content.pinnedPerryNames { addRow("◆ \(name)", color: .labelColor) }
            if let answer = content.lastAnswer, !answer.isEmpty {
                addRow(truncated(answer), color: .secondaryLabelColor)
            }
        }
        let hint = NSTextField(labelWithString: "Click or ⌃⌘Space to open Home")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(hint)
        setAccessibilityLabel(accessibilitySummary())
    }

    private func addHeading(_ text: String) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(label)
    }

    private func addRow(_ text: String, color: NSColor) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11.5)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2
        stack.addArrangedSubview(label)
    }

    private func truncated(_ text: String) -> String {
        let oneLine = text.components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return oneLine.count > 90 ? String(oneLine.prefix(90)) + "…" : oneLine
    }

    private func accessibilitySummary() -> String {
        var parts = ["Perry Home peek"]
        parts.append(contentsOf: content.agentLines)
        if content.unreadCount > 0 { parts.append("\(content.unreadCount) unread") }
        parts.append(contentsOf: content.pinnedPerryNames)
        return parts.joined(separator: ", ")
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onOpenHome?()
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
