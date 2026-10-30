import Foundation
import PerryGuide

#if DEBUG
enum GuideDrillRecorder {
    static let enabled = !Set(ProcessInfo.processInfo.arguments).isDisjoint(with: ["--perry-guide-drill", "--perry-guide-live"])
    private static let statePath = ProcessInfo.processInfo.environment["PERRY_GUIDE_DRILL_STATE"]
        ?? NSTemporaryDirectory() + "perry-guide-drill-state.json"
    private static var sequence = 0

    static func presented(_ presentation: GuidePresentation) {
        guard enabled else { return }
        sequence += 1
        let target = presentation.target
        write([
            "seq": sequence,
            "instruction": presentation.step.instruction,
            "done": false,
            "hasTarget": target != nil,
            "targetLabel": target?.label ?? "",
            "targetRole": target?.role.rawValue ?? "",
            "x": target?.frame.x ?? 0,
            "y": target?.frame.y ?? 0,
            "w": target?.frame.width ?? 0,
            "h": target?.frame.height ?? 0,
            "targetID": target?.stableID ?? "",
            "postcondition": presentation.step.postcondition.flatMap { try? String(data: JSONEncoder().encode($0), encoding: .utf8) } ?? ""
        ])
    }

    static func status(_ status: String) {
        guard enabled else { return }
        sequence += 1
        write(["seq": sequence, "status": status])
    }

    static func finished() {
        guard enabled else { return }
        sequence += 1
        write(["seq": sequence, "instruction": "", "done": true])
    }

    private static func write(_ record: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: record) else { return }
        let stateURL = URL(fileURLWithPath: statePath)
        try? data.write(to: stateURL, options: .atomic)
        if let handle = FileHandle(forWritingAtPath: statePath + ".log")
            ?? (FileManager.default.createFile(atPath: statePath + ".log", contents: nil) ? FileHandle(forWritingAtPath: statePath + ".log") : nil) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.write(Data([0x0a]))
            try? handle.close()
        }
    }
}
#endif
