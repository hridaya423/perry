// scripts/lab/codex-appserver-spike.swift
// Phase 0 spike: drive `codex app-server` over stdio JSON-RPC and measure
// spawn→initialize and turn/start→first agentMessage delta. Run:
//   swift scripts/lab/codex-appserver-spike.swift [--codex /path/to/codex]
//     [--codex-home ~/.codex] [--model <id> ...] [--no-image]
import Foundation

var codexPath = "App/Resources/CodexRuntime/bin/codex"
var codexHome = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".codex").path
var models: [String] = []
var withImage = true
var verbose = false
var effort: String?
var turnsPerThread = 1
var freshThreadPerTurn = false
var imagePathArg: String?
var dataURLImage = false
var promptArg = "what does this do"
var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--codex": codexPath = args.next() ?? codexPath
    case "--codex-home": codexHome = args.next() ?? codexHome
    case "--model": if let m = args.next() { models.append(m) }
    case "--no-image": withImage = false
    case "--verbose": verbose = true
    case "--effort": effort = args.next()
    case "--turns": turnsPerThread = Int(args.next() ?? "") ?? 1
    case "--fresh-thread-per-turn": freshThreadPerTurn = true
    case "--image-path": imagePathArg = args.next()
    case "--data-url-image": dataURLImage = true
    case "--prompt": promptArg = args.next() ?? promptArg
    default: fputs("unknown arg: \(arg)\n", stderr)
    }
}
if !codexPath.hasPrefix("/") {
    codexPath = FileManager.default.currentDirectoryPath + "/" + codexPath
}

func now() -> Double { Date().timeIntervalSince1970 * 1000 }

final class JSONRPC {
    let process = Process()
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    var nextID = 0
    var incoming: [[String: Any]] = []
    let lock = NSLock()
    var buffered = Data()

    func spawn() throws {
        process.executableURL = URL(fileURLWithPath: codexPath)
        process.arguments = ["app-server"]
        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = codexHome
        process.environment = env
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let out = stdoutPipe.fileHandleForReading
        Thread.detachNewThread { [weak self] in
            while true {
                let chunk = out.availableData
                if chunk.isEmpty { return }
                self?.ingest(chunk)
            }
        }
    }

    func ingest(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        buffered.append(chunk)
        while let nl = buffered.firstIndex(of: 0x0A) {
            let line = buffered.subdata(in: 0..<nl)
            buffered.removeSubrange(0...nl)
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            else { continue }
            incoming.append(obj)
        }
    }

    func send(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        stdinPipe.fileHandleForWriting.write(data)
        stdinPipe.fileHandleForWriting.write(Data([0x0A]))
    }

    func request(_ method: String, _ params: [String: Any]) -> Int {
        nextID += 1
        send(["id": nextID, "method": method, "params": params])
        return nextID
    }

    func notify(_ method: String, _ params: [String: Any] = [:]) {
        send(["method": method, "params": params])
    }

    /// Poll for a matching message until deadline (ms from now). Returns message.
    func wait(until deadline: Double, match: ([String: Any]) -> Bool) -> [String: Any]? {
        while now() < deadline {
            lock.lock()
            if let idx = incoming.firstIndex(where: match) {
                let m = incoming.remove(at: idx)
                lock.unlock()
                return m
            }
            lock.unlock()
            Thread.sleep(forTimeInterval: 0.005)
        }
        return nil
    }
}

let t0 = now()
let rpc = JSONRPC()
do { try rpc.spawn() } catch {
    print("{\"error\":\"spawn failed: \(error)\"}")
    exit(1)
}
var report: [String: Any] = ["codex_home": codexHome]

let initID = rpc.request("initialize", [
    "clientInfo": ["name": "perry-lab-spike", "version": "0.1.0"],
    "capabilities": ["experimentalApi": true],
])
guard rpc.wait(until: t0 + 30_000, match: { ($0["id"] as? Int) == initID }) != nil else {
    print("{\"error\":\"initialize timeout\"}")
    rpc.process.terminate()
    exit(1)
}
let tInit = now()
report["spawn_to_initialized_ms"] = tInit - t0
rpc.notify("initialized")

let acctID = rpc.request("account/read", [:])
if let resp = rpc.wait(until: now() + 15_000, match: { ($0["id"] as? Int) == acctID }) {
    report["account_read"] = resp["result"] ?? resp["error"] ?? "?"
}

let modelID = rpc.request("model/list", [:])
var listedModels: [String] = []
if let resp = rpc.wait(until: now() + 15_000, match: { ($0["id"] as? Int) == modelID }),
   let result = resp["result"] as? [String: Any],
   let data = result["data"] as? [[String: Any]] {
    listedModels = data.compactMap { $0["model"] as? String ?? $0["id"] as? String }
}
report["models"] = listedModels

if models.isEmpty, let first = listedModels.first { models = [first] }

var imagePath = imagePathArg ?? ""
if withImage && imagePath.isEmpty {
    imagePath = "/tmp/perry-spike-px.png"
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAATSURBVBhXY/iPA4aGhoaGhgYGBgYAI3wCAd2vyyEAAAAASUVORK5CYII=") ?? Data()
    try? png.write(to: URL(fileURLWithPath: imagePath))
}

func startThread(_ model: String) -> (id: String?, startMs: Double) {
    let t = now()
    let threadID = rpc.request("thread/start", [
        "ephemeral": true,
        "model": model,
        "approvalPolicy": "never",
        "sandbox": "read-only",
    ])
    guard let resp = rpc.wait(until: t + 30_000, match: { ($0["id"] as? Int) == threadID }),
          let result = resp["result"] as? [String: Any],
          let thread = result["thread"] as? [String: Any],
          let tid = thread["id"] as? String else {
        return (nil, now() - t)
    }
    return (tid, now() - t)
}

var turns: [[String: Any]] = []
for model in models {
    var tid: String?
    for turnIndex in 0..<turnsPerThread {
        var threadStartMs: Double = 0
        if tid == nil || freshThreadPerTurn {
            let started = startThread(model)
            threadStartMs = started.startMs
            guard let newTid = started.id else {
                turns.append(["model": model, "turn": turnIndex, "error": "thread/start failed"])
                continue
            }
            tid = newTid
        }
        var input: [[String: Any]] = [["type": "text", "text": promptArg]]
        if withImage {
            if dataURLImage, let data = try? Data(contentsOf: URL(fileURLWithPath: imagePath)) {
                input.append(["type": "inputImage", "imageUrl": "data:image/png;base64,\(data.base64EncodedString())"])
            } else {
                input.append(["type": "localImage", "path": imagePath])
            }
        }
        while rpc.wait(until: now() + 100, match: { _ in true }) != nil {}
        let tTurn = now()
        var turnParams: [String: Any] = ["threadId": tid!, "input": input]
        if let effort { turnParams["effort"] = effort }
        let turnReq = rpc.request("turn/start", turnParams)
        _ = rpc.wait(until: now() + 15_000, match: { ($0["id"] as? Int) == turnReq })
        var firstDelta: Double?
        var firstItem: Double?
        var completed = false
        var turnError = ""
        while now() < tTurn + 90_000, !completed {
            guard let msg = rpc.wait(until: now() + 500, match: { _ in true }) else { continue }
            let method = msg["method"] as? String ?? ""
            if verbose { fputs(String("\(method) \(msg["params"] ?? "")".prefix(400)) + "\n", stderr) }
            if method == "item/started", firstItem == nil { firstItem = now() }
            if method == "item/agentMessage/delta", firstDelta == nil {
                firstDelta = now()
            } else if method == "item/completed", firstDelta == nil,
                      let params = msg["params"] as? [String: Any],
                      let item = params["item"] as? [String: Any],
                      item["type"] as? String == "agentMessage" {
                firstDelta = now()
            } else if method == "turn/completed" {
                completed = true
            } else if method == "error" {
                turnError = String(describing: msg["params"] ?? "")
                completed = true
            }
        }
        var entry: [String: Any] = ["model": model, "turn": turnIndex, "thread_start_ms": threadStartMs]
        entry["first_item_ms"] = firstItem.map { $0 - tTurn }
        entry["first_delta_ms"] = firstDelta.map { $0 - tTurn }
        entry["completed"] = completed
        if !turnError.isEmpty { entry["error"] = turnError }
        turns.append(entry)
    }
}
report["turns"] = turns

rpc.process.terminate()
print(String(data: try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]), encoding: .utf8)!)
