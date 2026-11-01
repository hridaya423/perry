import AppKit

let logURL = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/perry-hybrid-fixture.log")

func log(_ line: String) {
    let data = Data((line + "\n").utf8)
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: logURL)
    }
}

final class Canvas: NSView {
    private var hue: CGFloat = 0.1
    private var dragStart: NSPoint?
    private var dragged = false

    override var isFlipped: Bool { true }
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(hue: hue, saturation: 0.6, brightness: 0.9, alpha: 1).setFill()
        bounds.fill()
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        dragged = true
    }

    override func mouseUp(with event: NSEvent) {
        let end = convert(event.locationInWindow, from: nil)
        guard let start = dragStart else { return }
        if dragged {
            log("canvas-drag \(Int(start.x)) \(Int(start.y)) \(Int(end.x)) \(Int(end.y))")
        } else {
            log("canvas-click \(Int(end.x)) \(Int(end.y))")
        }
        hue = (hue + 0.27).truncatingRemainder(dividingBy: 1)
        needsDisplay = true
    }
}

final class MouseOnlyButton: NSButton {
    override func accessibilityPerformPress() -> Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class Controller: NSObject {
    var works = 0
    var inert = 0
    var send = 0

    @objc func pressWorks(_ sender: NSButton) {
        works += 1
        log("works \(NSApp.currentEvent?.type == .leftMouseUp ? "mouse" : "ax")")
        sender.title = "Works \(works)"
    }

    @objc func pressInert(_ sender: NSButton) {
        inert += 1
        log("inert mouse")
        sender.title = "Inert \(inert)"
    }

    @objc func pressSend(_ sender: NSButton) {
        send += 1
        log("send mouse")
        sender.title = "Send \(send)"
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let controller = Controller()
let window = NSWindow(contentRect: NSRect(x: 120, y: 200, width: 520, height: 360), styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "Perry Hybrid Fixture"
let content = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 360))
let canvas = Canvas(frame: NSRect(x: 20, y: 100, width: 480, height: 240))
content.addSubview(canvas)

func button(_ cls: NSButton.Type, _ title: String, _ x: CGFloat, _ action: Selector) {
    let b = cls.init(frame: NSRect(x: x, y: 30, width: 140, height: 40))
    b.title = title
    b.bezelStyle = .rounded
    b.target = controller
    b.action = action
    content.addSubview(b)
}

button(NSButton.self, "Works", 20, #selector(Controller.pressWorks(_:)))
button(MouseOnlyButton.self, "Inert", 190, #selector(Controller.pressInert(_:)))
button(MouseOnlyButton.self, "Send", 360, #selector(Controller.pressSend(_:)))
window.contentView = content
window.orderFrontRegardless()
log("ready \(ProcessInfo.processInfo.processIdentifier) \(window.windowNumber)")
app.run()
