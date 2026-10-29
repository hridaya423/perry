import Foundation
import os

struct KokoroVoice: NeuralVoice {
    static let defaultVoice = "af_heart"
    static let voices: [CloudVoiceOption] = [
        CloudVoiceOption(id: "af_heart", name: "Heart", detail: "Warm, American"),
        CloudVoiceOption(id: "af_bella", name: "Bella", detail: "Bright, American"),
        CloudVoiceOption(id: "am_michael", name: "Michael", detail: "Calm, American"),
        CloudVoiceOption(id: "bf_emma", name: "Emma", detail: "Clear, British"),
        CloudVoiceOption(id: "bm_george", name: "George", detail: "Low, British"),
    ]
    static let voicePreferenceKey = "perry.speech.kokoroVoice"

    let voice: String
    let speed: Double

    var spellsNumbers: Bool { false }

    static var modelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Perry/Voices/Kokoro", isDirectory: true)
    }

    static var usesLegacyRoute: Bool { ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 }

    static var helperArguments: [String] {
        ["--models", modelsDirectory.path] + (usesLegacyRoute ? ["--legacy"] : [])
    }

    private static var marker: URL {
        modelsDirectory.appendingPathComponent(usesLegacyRoute ? ".installed-ane" : ".installed")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: marker.path)
    }

    static func installed(speed: Double) -> KokoroVoice? {
        guard isInstalled, !KokoroHelper.shared.crashed else { return nil }
        let voice = UserDefaults.standard.string(forKey: voicePreferenceKey) ?? defaultVoice
        return KokoroVoice(voice: voice, speed: speed)
    }

    func audio(for text: String, previous: String?) -> AsyncThrowingStream<Data, Error> {
        let request = KokoroHelper.Request(text: text, voice: voice, speed: Float(speed))
        return AsyncThrowingStream { continuation in
            KokoroHelper.shared.synthesize(request) { result in
                switch result {
                case .success(let pcm):
                    continuation.yield(pcm)
                    continuation.finish()
                case .failure(let error):
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    static func install(progress: @escaping @Sendable (String) -> Void) async throws {
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "perry-voice") else {
            throw NeuralSpeechError(message: "The local voice helper is missing from this build.")
        }
        let process = Process()
        process.executableURL = helper
        process.arguments = ["--install"] + helperArguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        progress("Downloading the voice…")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: NeuralSpeechError(message: "The local voice did not finish installing. Check the network and try again."))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        FileManager.default.createFile(atPath: marker.path, contents: Data())
        if usesLegacyRoute {
            try? FileManager.default.removeItem(at: modelsDirectory.appendingPathComponent("kokoro-82m-coreml/ANE-v3"))
            try? FileManager.default.removeItem(at: modelsDirectory.appendingPathComponent(".installed"))
        }
        progress("Ready")
    }
}

@MainActor
final class KokoroInstaller: ObservableObject {
    static let shared = KokoroInstaller()

    @Published private(set) var downloading = false
    @Published private(set) var failure: String?

    func start() {
        guard !downloading, !KokoroVoice.isInstalled,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        downloading = true
        failure = nil
        Task {
            do {
                try await KokoroVoice.install { _ in }
            } catch {
                failure = error.localizedDescription
            }
            downloading = false
        }
    }
}

final class KokoroHelper: @unchecked Sendable {
    struct Request: Encodable {
        let text: String
        let voice: String
        let speed: Float
    }

    static let shared = KokoroHelper()

    private let queue = DispatchQueue(label: "dev.perry.kokoro")
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var idleTimer: DispatchWorkItem?
    private let crashFlag = OSAllocatedUnfairLock(initialState: false)

    var crashed: Bool { crashFlag.withLock { $0 } }

    func warm() {
        queue.async { [self] in
            _ = try? started()
            scheduleIdleExit()
        }
    }

    private func scheduleIdleExit() {
        idleTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in self?.terminate() }
        idleTimer = timer
        queue.asyncAfter(deadline: .now() + 60, execute: timer)
    }

    func synthesize(_ request: Request, completion: @escaping (Result<Data, Error>) -> Void) {
        queue.async { [self] in
            idleTimer?.cancel()
            completion(Result { try run(request) })
            scheduleIdleExit()
        }
    }

    private func run(_ request: Request) throws -> Data {
        let (input, output) = try started()
        var line = try JSONEncoder().encode(request)
        line.append(0x0A)
        try input.write(contentsOf: line)
        let header = try readHeader(output)
        if let error = header["error"] as? String, (header["bytes"] as? Int ?? 0) == 0 {
            throw NeuralSpeechError(message: "The local voice failed: \(error)")
        }
        let count = header["bytes"] as? Int ?? 0
        var pcm = Data()
        while pcm.count < count {
            guard let chunk = try output.read(upToCount: count - pcm.count), !chunk.isEmpty else {
                crashFlag.withLock { $0 = true }
                terminate()
                throw NeuralSpeechError(message: "The local voice stopped unexpectedly.")
            }
            pcm.append(chunk)
        }
        return pcm
    }

    private func started() throws -> (FileHandle, FileHandle) {
        if let process, process.isRunning, let input, let output { return (input, output) }
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "perry-voice") else {
            throw NeuralSpeechError(message: "The local voice helper is missing from this build.")
        }
        let process = Process()
        process.executableURL = helper
        process.arguments = KokoroVoice.helperArguments
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        let ready = try readHeader(stdout.fileHandleForReading)
        guard ready["ready"] as? Bool == true else {
            terminate()
            throw NeuralSpeechError(message: "The local voice could not start.")
        }
        return (stdin.fileHandleForWriting, stdout.fileHandleForReading)
    }

    private func readHeader(_ handle: FileHandle) throws -> [String: Any] {
        var line = Data()
        while true {
            guard let byte = try handle.read(upToCount: 1), let value = byte.first else {
                crashFlag.withLock { $0 = true }
                terminate()
                throw NeuralSpeechError(message: "The local voice stopped unexpectedly.")
            }
            if value == 0x0A { break }
            line.append(value)
        }
        return (try JSONSerialization.jsonObject(with: line) as? [String: Any]) ?? [:]
    }

    private func terminate() {
        process?.terminate()
        process = nil
        input = nil
        output = nil
    }
}
