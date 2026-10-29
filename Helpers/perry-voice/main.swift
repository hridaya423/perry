import FluidAudio
import Foundation

struct Request: Decodable {
    let text: String
    let voice: String?
    let speed: Float?
}

let arguments = CommandLine.arguments
let directory = arguments.firstIndex(of: "--models").flatMap { arguments.indices.contains($0 + 1) ? URL(fileURLWithPath: arguments[$0 + 1]) : nil }
let output = FileHandle.standardOutput

func send(_ header: [String: Any], payload: Data = Data()) {
    var line = (try? JSONSerialization.data(withJSONObject: header)) ?? Data("{}".utf8)
    line.append(0x0A)
    output.write(line)
    if !payload.isEmpty { output.write(payload) }
}

func makeManager() -> KokoroAneManager {
    if #available(macOS 15, *), !arguments.contains("--legacy") {
        return KokoroAneManager(directory: directory, version: .v3)
    }
    return KokoroAneManager(directory: directory)
}

let manager = makeManager()
let semaphore = DispatchSemaphore(value: 0)

Task {
    do {
        try await manager.initialize(preloadVoices: ["af_heart"])
        if !arguments.contains("--install") { _ = try await manager.synthesizeDetailed(text: "Hi.") }
        send(["ready": true])
    } catch {
        send(["error": "\(error)"])
        exit(1)
    }
    if arguments.contains("--install") { exit(0) }
    while let line = readLine(strippingNewline: true) {
        guard let request = try? JSONDecoder().decode(Request.self, from: Data(line.utf8)) else {
            send(["error": "bad request"])
            continue
        }
        do {
            let result = try await manager.synthesizeDetailed(text: request.text, voice: request.voice, speed: request.speed ?? 1)
            var pcm = Data(capacity: result.samples.count * 2)
            for sample in result.samples {
                var value = Int16(max(-1, min(1, sample)) * 32_767).littleEndian
                withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
            }
            send(["bytes": pcm.count, "rate": result.sampleRate], payload: pcm)
        } catch {
            send(["error": "\(error)", "bytes": 0])
        }
    }
    semaphore.signal()
}
semaphore.wait()
