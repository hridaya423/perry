import ApplicationServices
import AppKit
import Foundation

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

enum Mode: String, CaseIterable {
    case single
    case batched
    case batchedVisible
}

struct Counters {
    var ipc = 0
    var nodes = 0
}

let batchNames: [CFString] = [
    kAXPositionAttribute as CFString, kAXSizeAttribute as CFString, kAXRoleAttribute as CFString,
    kAXTitleAttribute as CFString, "AXLabel" as CFString, kAXValueAttribute as CFString,
    kAXDescriptionAttribute as CFString, kAXHelpAttribute as CFString, kAXRoleDescriptionAttribute as CFString,
    kAXIdentifierAttribute as CFString, kAXEnabledAttribute as CFString, kAXSelectedAttribute as CFString,
    kAXFocusedAttribute as CFString, kAXPlaceholderValueAttribute as CFString, kAXChildrenAttribute as CFString,
]

let singleNames: [CFString] = [
    kAXRoleAttribute as CFString, kAXTitleAttribute as CFString, kAXValueAttribute as CFString,
    kAXDescriptionAttribute as CFString, kAXIdentifierAttribute as CFString, kAXHelpAttribute as CFString,
    kAXPositionAttribute as CFString, kAXSizeAttribute as CFString, kAXEnabledAttribute as CFString,
]

let listRoles: Set<String> = ["AXOutline", "AXTable", "AXList", "AXBrowser"]

func copy(_ element: AXUIElement, _ name: CFString, _ c: inout Counters) -> CFTypeRef? {
    c.ipc += 1
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name, &value) == .success ? value : nil
}

func walkSingle(_ element: AXUIElement, depth: Int, max: Int, _ c: inout Counters) {
    guard depth < max, c.nodes < 1000 else { return }
    AXUIElementSetMessagingTimeout(element, 2.0)
    c.nodes += 1
    for name in singleNames { _ = copy(element, name, &c) }
    c.ipc += 1
    var names: CFArray?
    _ = AXUIElementCopyActionNames(element, &names)
    guard let children = copy(element, kAXChildrenAttribute as CFString, &c) as? [AXUIElement] else { return }
    for child in children { walkSingle(child, depth: depth + 1, max: max, &c) }
}

func walkBatched(_ element: AXUIElement, depth: Int, max: Int, visibleOnly: Bool, _ c: inout Counters) {
    guard depth < max, c.nodes < 1000 else { return }
    AXUIElementSetMessagingTimeout(element, 2.0)
    c.nodes += 1
    c.ipc += 1
    var raw: CFArray?
    guard AXUIElementCopyMultipleAttributeValues(element, batchNames as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
          let values = raw as? [Any], values.count == batchNames.count else { return }
    let role = values[2] as? String ?? ""
    var children = values[14] as? [AXUIElement] ?? []
    if visibleOnly, listRoles.contains(role) {
        c.ipc += 1
        var visibleRaw: CFArray?
        let names = ["AXVisibleRows" as CFString, "AXVisibleChildren" as CFString]
        if AXUIElementCopyMultipleAttributeValues(element, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &visibleRaw) == .success,
           let visible = visibleRaw as? [Any] {
            if let rows = visible[0] as? [AXUIElement], !rows.isEmpty {
                children = rows
            } else if let kids = visible[1] as? [AXUIElement], !kids.isEmpty {
                children = kids
            }
        }
    }
    for child in children { walkBatched(child, depth: depth + 1, max: max, visibleOnly: visibleOnly, &c) }
}

func windowElement(pid: pid_t, windowID: CGWindowID?) -> AXUIElement? {
    let app = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement] else { return nil }
    guard let windowID else { return windows.first }
    return windows.first { window in
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(window, &id) == .success && id == windowID
    }
}

let args = CommandLine.arguments
guard args.count >= 2, let pidValue = Int32(args[1]) else {
    FileHandle.standardError.write(Data("usage: ax-walk-micro <pid> [windowID] [repeats] [maxDepth]\n".utf8))
    exit(2)
}
let windowID = args.count > 2 ? CGWindowID(args[2]) : nil
let repeats = args.count > 3 ? Int(args[3]) ?? 10 : 10
let maxDepth = args.count > 4 ? Int(args[4]) ?? 12 : 12

guard AXIsProcessTrusted() else {
    FileHandle.standardError.write(Data("not AX-trusted: grant Accessibility to the host that launched this binary\n".utf8))
    exit(3)
}
guard let window = windowElement(pid: pidValue, windowID: windowID) else {
    FileHandle.standardError.write(Data("window not found\n".utf8))
    exit(4)
}

func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    return sorted[sorted.count / 2]
}

for mode in Mode.allCases {
    var times: [Double] = []
    var last = Counters()
    for _ in 0..<(repeats + 1) {
        var counters = Counters()
        let start = DispatchTime.now().uptimeNanoseconds
        switch mode {
        case .single: walkSingle(window, depth: 0, max: maxDepth, &counters)
        case .batched: walkBatched(window, depth: 0, max: maxDepth, visibleOnly: false, &counters)
        case .batchedVisible: walkBatched(window, depth: 0, max: maxDepth, visibleOnly: true, &counters)
        }
        times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        last = counters
    }
    times.removeFirst()
    print("\(mode.rawValue)\tnodes=\(last.nodes)\tipc=\(last.ipc)\tp50_ms=\(String(format: "%.1f", median(times)))\tmin_ms=\(String(format: "%.1f", times.min() ?? 0))\tmax_ms=\(String(format: "%.1f", times.max() ?? 0))")
}
