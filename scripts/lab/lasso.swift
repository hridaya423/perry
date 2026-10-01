import Cocoa

// lasso.swift — post a synthetic ⌥⌘ circle-select gesture into the session
// event stream. Perry's SpatialInputMonitor (armed while the panel is
// invoked) observes it via global NSEvent monitors; watch for
// spatial.down → spatial.select → the spoken reply markers.
//
//   swiftc -o /tmp/lasso scripts/lab/lasso.swift && /tmp/lasso [cx cy size]
//
// Session-level posting reaches other processes' monitors without HID
// trust (unlike .cghidEventTap). The real cursor is warped along the path
// because Perry's point source falls back to NSEvent.mouseLocation when
// the delivered event's cgEvent is nil — the saved position is restored
// at the end. Keep gestures small; the user may be at the machine.
let src = CGEventSource(stateID: .hidSystemState)
let flags: CGEventFlags = [.maskCommand, .maskAlternate]

let saved = CGEvent(source: nil)?.location ?? .zero

func post(_ type: CGEventType, _ p: CGPoint) {
    CGWarpMouseCursorPosition(p)
    guard let ev = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left) else { return }
    ev.flags = flags
    ev.post(tap: .cgSessionEventTap)
}

let args = CommandLine.arguments
let cx: CGFloat = args.count > 1 ? CGFloat(Double(args[1]) ?? 560) : 560
let cy: CGFloat = args.count > 2 ? CGFloat(Double(args[2]) ?? 220) : 220
let s: CGFloat = args.count > 3 ? CGFloat(Double(args[3]) ?? 110) : 110
var path: [CGPoint] = []
let steps = 6
for i in 0...steps { path.append(CGPoint(x: cx + s*CGFloat(i)/CGFloat(steps), y: cy)) }
for i in 0...steps { path.append(CGPoint(x: cx + s, y: cy + s*CGFloat(i)/CGFloat(steps))) }
for i in 0...steps { path.append(CGPoint(x: cx + s - s*CGFloat(i)/CGFloat(steps), y: cy + s)) }
for i in 0...steps { path.append(CGPoint(x: cx, y: cy + s - s*CGFloat(i)/CGFloat(steps))) }

post(.leftMouseDown, path[0])
usleep(80000)
for p in path.dropFirst() { post(.leftMouseDragged, p); usleep(25000) }
post(.leftMouseUp, path.last!)
usleep(60000)
CGWarpMouseCursorPosition(saved)
fputs("lasso posted: \(path.count) points, pointer restored to \(saved)\n", stderr)
