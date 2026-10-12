import Foundation
import AppKit

// Lab driver for the DEBUG `--perry-guide-drill` seam: posts the
// app.perry.guide-drill* distributed notifications Perry listens for.
//   guide-drill start <goal>     begin a guide session for <goal>
//   guide-drill click <x> <y>    inject a click at AX-space point (x, y)
//   guide-drill stop             dismiss the active guide
//   guide-drill frontmost        print the frontmost app's bundle id

let args = CommandLine.arguments

func post(_ name: String, userInfo: [String: Any] = [:]) {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name(name), object: nil, userInfo: userInfo,
        deliverImmediately: true
    )
}

guard args.count >= 2 else {
    FileHandle.standardError.write("usage: guide-drill {start <goal>|click <x> <y>|stop}\n".data(using: .utf8)!)
    exit(2)
}

switch args[1] {
case "start":
    guard args.count >= 3, !args[2].isEmpty else {
        FileHandle.standardError.write("guide-drill start needs a goal\n".data(using: .utf8)!)
        exit(2)
    }
    post("app.perry.guide-drill", userInfo: ["goal": args[2]])
case "click":
    guard args.count >= 4, let x = Double(args[2]), let y = Double(args[3]) else {
        FileHandle.standardError.write("guide-drill click needs numeric x y\n".data(using: .utf8)!)
        exit(2)
    }
    post("app.perry.guide-drill-click", userInfo: ["x": NSNumber(value: x), "y": NSNumber(value: y)])
case "stop":
    post("app.perry.guide-drill-stop")
case "frontmost":
    print(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
default:
    FileHandle.standardError.write("unknown subcommand '\(args[1])'\n".data(using: .utf8)!)
    exit(2)
}
// The notification is handed to the connection before return; a short pause
// keeps a fast exit from racing the flush on some systems.
usleep(30_000)
