import AppKit

// Deterministic Talk-drill target: a real window with a keypad of AXButtons at
// stable positions, so drills never depend on a third-party app's window state.
// Run: swift scripts/lab/drill-target.swift  (stays in front until killed)

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let grid = ["7", "8", "9", "4", "5", "6", "1", "2", "3", "0", "=", "C"]
let columns = 3
let cell: CGFloat = 64
let pad: CGFloat = 12
let rows = grid.count / columns
let width = pad * 2 + cell * CGFloat(columns)
let height = pad * 2 + cell * CGFloat(rows)

let window = NSWindow(
    contentRect: NSRect(x: 500, y: 300, width: width, height: height),
    styleMask: [.titled, .closable],
    backing: .buffered,
    defer: false
)
window.title = "Drill Target"

for (index, title) in grid.enumerated() {
    let col = CGFloat(index % columns)
    let row = CGFloat(index / columns)
    let button = NSButton(title: title, target: nil, action: nil)
    button.bezelStyle = .rounded
    button.frame = NSRect(
        x: pad + col * cell,
        y: pad + (CGFloat(rows - 1) - row) * cell,
        width: cell - 8,
        height: cell - 8
    )
    window.contentView?.addSubview(button)
}

window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
// Stage Manager stages the window of any app that loses focus, collapsing its
// reported bounds to an edge thumbnail — re-assert frontmost on a timer so the
// drill's target keeps a real frame.
Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
    app.activate(ignoringOtherApps: true)
}
app.run()
