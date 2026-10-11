import Cocoa

// talk-hold.swift — drive a synthetic ⌃⌥ hold for the talk drill.
//
//   swiftc -O -o /tmp/talk-hold scripts/lab/talk-hold.swift
//   /tmp/talk-hold [cx cy holdSeconds]
//
// Perry's ModifierHoldMonitor is driven via its DEBUG-only drill trigger:
// the app observes `app.perry.talk-drill` distributed notifications and feeds
// each phase through the monitor's `handle` seam — the same entry point its
// event tap calls — so commit timing, cancellation, and PerfMarks all run
// the production path. The pointer is warped to (cx, cy) — the AX top-left
// origin space CGWarpMouseCursorPosition and the trace samples share — so
// DeixisResolver hit-tests a live point, then the saved position is
// restored. Keep the user away from the machine during a run.
let center = DistributedNotificationCenter.default()
let name = Notification.Name("app.perry.talk-drill")

let args = CommandLine.arguments
let cx: CGFloat = args.count > 1 ? CGFloat(Double(args[1]) ?? 0) : 0
let cy: CGFloat = args.count > 2 ? CGFloat(Double(args[2]) ?? 0) : 0
let holdSeconds: Double = args.count > 3 ? Double(args[3]) ?? 1.6 : 1.6

let saved = CGEvent(source: nil)?.location ?? .zero

func post(_ phase: String) {
    center.postNotificationName(name, object: nil, userInfo: ["phase": phase], deliverImmediately: true)
}

if cx != 0 || cy != 0 {
    CGWarpMouseCursorPosition(CGPoint(x: cx, y: cy))
}
usleep(80_000)
post("down")
usleep(useconds_t(holdSeconds * 1_000_000))
post("up")
usleep(60_000)
CGWarpMouseCursorPosition(saved)
fputs("talk-hold posted: \(holdSeconds)s at (\(cx), \(cy))\n", stderr)
