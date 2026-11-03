import AppKit
import CryptoKit
import WebKit

let logURL = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/perry-torture-fixture.log")
let windowTitle = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "Perry Torture Fixture"

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

func encoded(_ text: String) -> String {
    Data(text.utf8).base64EncodedString()
}

func digest(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

func via() -> String {
    switch NSApp.currentEvent?.type {
    case .leftMouseUp, .leftMouseDown: return "mouse"
    case .keyDown, .keyUp: return "key"
    default: return "ax"
    }
}

final class Flipped: NSView {
    override var isFlipped: Bool { true }
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
            log("canvas-click \(Int(end.x)) \(Int(end.y)) \(event.clickCount)")
        }
        hue = (hue + 0.27).truncatingRemainder(dividingBy: 1)
        needsDisplay = true
    }

    override func rightMouseUp(with event: NSEvent) {
        let end = convert(event.locationInWindow, from: nil)
        log("canvas-right \(Int(end.x)) \(Int(end.y))")
    }
}

final class MouseOnlyButton: NSButton {
    override func accessibilityPerformPress() -> Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class Controller: NSObject, NSTextFieldDelegate, NSTextViewDelegate, NSTableViewDataSource, NSTableViewDelegate, WKScriptMessageHandler {
    var rows: NSStackView!
    var window: NSWindow!
    var later: NSButton!

    @objc func works(_ sender: NSButton) { log("works \(via())") }
    @objc func inert(_ sender: NSButton) { log("inert \(via())") }
    @objc func send(_ sender: NSButton) { log("send \(via())") }
    @objc func icon(_ sender: NSButton) { log("icon \(via())") }

    @objc func delete(_ sender: NSButton) {
        log("delete \(sender.tag) \(via())")
        if let row = sender.superview {
            rows.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
    }

    @objc func checkbox(_ sender: NSButton) {
        log("checkbox \(sender.state == .on ? "on" : "off") \(via())")
    }

    @objc func popup(_ sender: NSPopUpButton) {
        log("popup \(sender.titleOfSelectedItem ?? "") \(via())")
    }

    @objc func slow(_ sender: NSButton) {
        log("slow begin \(via())")
        Thread.sleep(forTimeInterval: 4)
        log("slow done")
    }

    @objc func laterPressed(_ sender: NSButton) {
        log("later \(via())")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { sender.title = "Later done" }
    }

    @objc func openSheet(_ sender: NSButton) {
        log("sheet open \(via())")
        let alert = NSAlert()
        alert.messageText = "Fixture sheet"
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Go back")
        alert.beginSheetModal(for: window) { response in
            log(response == .alertFirstButtonReturn ? "sheet continue" : "sheet back")
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field is NSSecureTextField {
            log("password \(digest(field.stringValue)) \(field.stringValue.count)")
        } else {
            log("name \(encoded(field.stringValue))")
        }
    }

    func textDidChange(_ notification: Notification) {
        guard let view = notification.object as? NSTextView else { return }
        log("notes \(encoded(view.string))")
    }

    func numberOfRows(in tableView: NSTableView) -> Int { 100 }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        "Item \(row + 1)"
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView, table.selectedRow >= 0 else { return }
        log("select \(table.selectedRow + 1) \(via())")
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? String else { return }
        log(body)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let controller = Controller()
let width: CGFloat = 900
let height: CGFloat = 720
let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: width, height: height), styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = windowTitle
controller.window = window
let content = Flipped(frame: NSRect(x: 0, y: 0, width: width, height: height))

func button(_ cls: NSButton.Type = NSButton.self, _ title: String, _ frame: NSRect, _ action: Selector, tag: Int = 0) -> NSButton {
    let b = cls.init(frame: frame)
    b.title = title
    b.bezelStyle = .rounded
    b.target = controller
    b.action = action
    b.tag = tag
    content.addSubview(b)
    return b
}

func label(_ text: String, _ frame: NSRect) {
    let field = NSTextField(labelWithString: text)
    field.frame = frame
    content.addSubview(field)
}

_ = button(NSButton.self, "Works", NSRect(x: 20, y: 20, width: 120, height: 32), #selector(Controller.works(_:)))
_ = button(MouseOnlyButton.self, "Inert", NSRect(x: 150, y: 20, width: 120, height: 32), #selector(Controller.inert(_:)))
_ = button(MouseOnlyButton.self, "Send", NSRect(x: 280, y: 20, width: 120, height: 32), #selector(Controller.send(_:)))
let iconButton = button(MouseOnlyButton.self, "", NSRect(x: 410, y: 20, width: 44, height: 32), #selector(Controller.icon(_:)))
iconButton.image = NSImage(systemSymbolName: "star", accessibilityDescription: nil)
_ = button(NSButton.self, "Slow", NSRect(x: 470, y: 20, width: 100, height: 32), #selector(Controller.slow(_:)))
controller.later = button(NSButton.self, "Later", NSRect(x: 580, y: 20, width: 120, height: 32), #selector(Controller.laterPressed(_:)))
_ = button(NSButton.self, "Open Sheet", NSRect(x: 710, y: 20, width: 160, height: 32), #selector(Controller.openSheet(_:)))

let rowStack = NSStackView(frame: NSRect(x: 20, y: 70, width: 260, height: 170))
rowStack.orientation = .vertical
rowStack.alignment = .leading
rowStack.spacing = 6
for index in 1...4 {
    let row = NSStackView()
    row.orientation = .horizontal
    let text = NSTextField(labelWithString: "Row \(index)")
    text.widthAnchor.constraint(equalToConstant: 80).isActive = true
    let delete = NSButton(title: "Delete", target: controller, action: #selector(Controller.delete(_:)))
    delete.tag = index
    row.addArrangedSubview(text)
    row.addArrangedSubview(delete)
    rowStack.addArrangedSubview(row)
}
content.addSubview(rowStack)
controller.rows = rowStack

label("Name", NSRect(x: 300, y: 74, width: 80, height: 20))
let nameField = NSTextField(frame: NSRect(x: 380, y: 70, width: 300, height: 26))
nameField.placeholderString = "Name"
nameField.setAccessibilityLabel("Name")
nameField.delegate = controller
content.addSubview(nameField)

label("Password", NSRect(x: 300, y: 114, width: 80, height: 20))
let passwordField = NSSecureTextField(frame: NSRect(x: 380, y: 110, width: 300, height: 26))
passwordField.setAccessibilityLabel("Password")
passwordField.delegate = controller
content.addSubview(passwordField)

let checkbox = NSButton(checkboxWithTitle: "Dark Mode", target: controller, action: #selector(Controller.checkbox(_:)))
checkbox.frame = NSRect(x: 300, y: 150, width: 160, height: 24)
content.addSubview(checkbox)

let popup = NSPopUpButton(frame: NSRect(x: 480, y: 148, width: 160, height: 28), pullsDown: false)
popup.addItems(withTitles: ["Small", "Medium", "Large"])
popup.setAccessibilityLabel("Size")
popup.target = controller
popup.action = #selector(Controller.popup(_:))
content.addSubview(popup)

label("Notes", NSRect(x: 300, y: 190, width: 80, height: 20))
let notesScroll = NSScrollView(frame: NSRect(x: 380, y: 186, width: 500, height: 90))
let notes = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 90))
notes.isRichText = false
notes.isAutomaticQuoteSubstitutionEnabled = false
notes.isAutomaticDashSubstitutionEnabled = false
notes.isAutomaticTextReplacementEnabled = false
notes.isAutomaticSpellingCorrectionEnabled = false
notes.setAccessibilityLabel("Notes")
notes.delegate = controller
notesScroll.documentView = notes
notesScroll.hasVerticalScroller = true
content.addSubview(notesScroll)
nameField.isAutomaticTextCompletionEnabled = false

let canvas = Canvas(frame: NSRect(x: 20, y: 300, width: 400, height: 200))
content.addSubview(canvas)

let tableScroll = NSScrollView(frame: NSRect(x: 440, y: 300, width: 200, height: 200))
let table = NSTableView(frame: tableScroll.bounds)
let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
column.title = "Items"
column.width = 180
table.addTableColumn(column)
table.dataSource = controller
table.delegate = controller
table.setAccessibilityLabel("Items")
tableScroll.documentView = table
tableScroll.hasVerticalScroller = true
content.addSubview(tableScroll)

let contentController = WKUserContentController()
contentController.add(controller, name: "fixture")
let configuration = WKWebViewConfiguration()
configuration.userContentController = contentController
let web = WKWebView(frame: NSRect(x: 660, y: 300, width: 220, height: 200), configuration: configuration)
let page = """
<html><body style="font: 14px -apple-system; margin: 8px">
<label for="q">Search</label><br>
<input id="q" aria-label="Search" style="width: 180px" oninput="webkit.messageHandlers.fixture.postMessage('web-input ' + btoa(unescape(encodeURIComponent(this.value))))"><br><br>
<button id="go" onclick="webkit.messageHandlers.fixture.postMessage('web-go ' + btoa(unescape(encodeURIComponent(document.getElementById('q').value))))">Go</button>
<a href="#" id="more" onclick="webkit.messageHandlers.fixture.postMessage('web-link'); return false">More results</a>
</body></html>
"""
web.loadHTMLString(page, baseURL: nil)
content.addSubview(web)

label("Status: idle", NSRect(x: 20, y: 520, width: 300, height: 20))

window.contentView = content
window.orderFrontRegardless()
log("ready \(ProcessInfo.processInfo.processIdentifier) \(window.windowNumber)")
app.run()
