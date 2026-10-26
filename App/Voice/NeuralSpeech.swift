import AVFoundation
import Foundation
import PerryBrain
import PerryGuide

protocol NeuralVoice: Sendable {
    var spellsNumbers: Bool { get }
    func audio(for text: String, previous: String?) -> AsyncThrowingStream<Data, Error>
}

struct NeuralSpeechError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class NeuralSpeechPlayer {
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!

    var onIdle: () -> Void = {}
    var onError: (String) -> Void = { _ in }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var generation = 0
    private var chain: Task<Void, Never>?
    private var queuedSentences = 0
    private var pendingBuffers = 0
    private var previousText: String?
    private var shutdown: DispatchWorkItem?

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: Self.format)
    }

    var isSpeaking: Bool { queuedSentences > 0 || pendingBuffers > 0 }

    func enqueue(_ text: String, voice: any NeuralVoice) {
        let stream = voice.audio(for: text, previous: previousText)
        previousText = text
        let generation = generation
        let prior = chain
        queuedSentences += 1
        chain = Task { [weak self] in
            await prior?.value
            guard let self, self.generation == generation else { return }
            do {
                var carry = Data()
                for try await chunk in stream {
                    guard self.generation == generation else { return }
                    carry.append(chunk)
                    let usable = carry.count - carry.count % 2
                    guard usable >= 4_800 else { continue }
                    self.schedule(carry.prefix(usable), generation: generation)
                    carry.removeFirst(usable)
                }
                if carry.count >= 2 { self.schedule(carry.prefix(carry.count - carry.count % 2), generation: generation) }
            } catch {
                guard self.generation == generation else { return }
                self.onError(error.localizedDescription)
            }
            guard self.generation == generation else { return }
            self.queuedSentences -= 1
            self.settleIfIdle()
        }
    }

    func stop() {
        generation += 1
        chain?.cancel()
        chain = nil
        queuedSentences = 0
        pendingBuffers = 0
        previousText = nil
        player.stop()
        scheduleShutdown()
    }

    private func schedule(_ pcm: Data, generation: Int) {
        let frames = AVAudioFrameCount(pcm.count / 2)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        let output = buffer.floatChannelData![0]
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for index in 0..<Int(frames) { output[index] = Float(Int16(littleEndian: samples[index])) / 32_768 }
        }
        shutdown?.cancel()
        if !engine.isRunning {
            do { try engine.start() } catch { return onError(error.localizedDescription) }
        }
        pendingBuffers += 1
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.pendingBuffers -= 1
                self.settleIfIdle()
            }
        }
        if !player.isPlaying { player.play() }
    }

    private func settleIfIdle() {
        guard !isSpeaking else { return }
        previousText = nil
        onIdle()
        scheduleShutdown()
    }

    private func scheduleShutdown() {
        shutdown?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isSpeaking else { return }
            self.player.stop()
            self.engine.stop()
        }
        shutdown = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
}

enum SpeechEngineChoice: Hashable, Sendable {
    case system
    case kokoro
    case cloud(CloudVoiceProvider)

    init?(rawValue: String) {
        switch rawValue {
        case "system": self = .system
        case "kokoro": self = .kokoro
        default:
            guard let provider = CloudVoiceProvider(rawValue: rawValue) else { return nil }
            self = .cloud(provider)
        }
    }

    var rawValue: String {
        switch self {
        case .system: "system"
        case .kokoro: "kokoro"
        case .cloud(let provider): provider.rawValue
        }
    }

    static var current: SpeechEngineChoice {
        SpeechEngineChoice(rawValue: PerryPreferences.speechEngine) ?? .system
    }
}

typealias CloudVoiceProvider = VoiceService

extension VoiceService: Identifiable {
    public var id: String { rawValue }

    var name: String {
        switch self {
        case .elevenLabs: "ElevenLabs"
        case .openAI: "OpenAI"
        case .cartesia: "Cartesia"
        }
    }

    var keyAccount: String { "voice.\(rawValue)" }

    var voicePreferenceKey: String { "perry.speech.cloudVoice.\(rawValue)" }

    var keysPage: URL {
        switch self {
        case .elevenLabs: URL(string: "https://elevenlabs.io/app/settings/api-keys")!
        case .openAI: URL(string: "https://platform.openai.com/api-keys")!
        case .cartesia: URL(string: "https://play.cartesia.ai/keys")!
        }
    }

    var defaultVoice: CloudVoiceOption {
        switch self {
        case .elevenLabs: CloudVoiceOption(id: "21m00Tcm4TlvDq8ikWAM", name: "Rachel")
        case .openAI: CloudVoiceOption(id: "marin", name: "Marin")
        case .cartesia: CloudVoiceOption(id: "db6b0ed5-d5d3-463d-ae85-518a07d3c2b4", name: "Cartesia default")
        }
    }

    static func provider(forKey key: String) -> CloudVoiceProvider? {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.wholeMatch(of: #/sk_car_[A-Za-z0-9_\-]{16,}/#) != nil { return .cartesia }
        if key.wholeMatch(of: #/sk_[0-9a-f]{40,64}/#) != nil { return .elevenLabs }
        if key.wholeMatch(of: #/sk-(?:proj-|svcacct-)?[A-Za-z0-9_\-]{32,}/#) != nil { return .openAI }
        return nil
    }

    func speechRequest(text: String, voiceID: String, key: String, previous: String?, speed: Double) -> URLRequest {
        var body: [String: Any]
        var request: URLRequest
        switch self {
        case .elevenLabs:
            request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)/stream?output_format=pcm_24000")!)
            request.setValue(key, forHTTPHeaderField: "xi-api-key")
            body = ["text": text, "model_id": "eleven_flash_v2_5",
                    "voice_settings": ["stability": 0.45, "similarity_boost": 0.8, "speed": min(max(speed, 0.7), 1.2)]]
            if let previous { body["previous_text"] = previous }
        case .openAI:
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            body = ["model": "gpt-4o-mini-tts", "voice": voiceID, "input": text, "response_format": "pcm",
                    "speed": min(max(speed, 0.5), 2),
                    "instructions": "Speak like a warm, relaxed friend. Natural pace, light and conversational."]
        case .cartesia:
            request = URLRequest(url: URL(string: "https://api.cartesia.ai/tts/bytes")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("2026-08-14", forHTTPHeaderField: "Cartesia-Version")
            body = ["model_id": "sonic-3.6", "transcript": text, "voice": ["id": voiceID], "language": "en",
                    "output_format": ["container": "raw", "encoding": "pcm_s16le", "sample_rate": 24_000]]
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    func voicesRequest(key: String) -> URLRequest? {
        var request: URLRequest
        switch self {
        case .elevenLabs:
            request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v2/voices?page_size=100")!)
            request.setValue(key, forHTTPHeaderField: "xi-api-key")
        case .openAI:
            request = URLRequest(url: URL(string: "https://api.openai.com/v1/models/gpt-4o-mini-tts")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .cartesia:
            request = URLRequest(url: URL(string: "https://api.cartesia.ai/voices?limit=100")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("2026-08-14", forHTTPHeaderField: "Cartesia-Version")
        }
        return request
    }

    func parseVoices(_ data: Data) -> [CloudVoiceOption] {
        switch self {
        case .openAI:
            return ["marin", "cedar", "coral", "sage", "ash", "ballad", "verse", "alloy"].map {
                CloudVoiceOption(id: $0, name: $0.capitalized)
            }
        case .elevenLabs, .cartesia:
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = (object["voices"] ?? object["data"]) as? [[String: Any]] else { return [] }
            return rows.compactMap { row in
                guard let id = (row["voice_id"] ?? row["id"]) as? String, let name = row["name"] as? String else { return nil }
                let labels = row["labels"] as? [String: Any]
                let detail = [labels?["accent"], labels?["description"] ?? row["description"]].compactMap { $0 as? String }.first
                return CloudVoiceOption(id: id, name: name, detail: detail)
            }
        }
    }

    func preferredVoice(in voices: [CloudVoiceOption]) -> CloudVoiceOption? {
        let favourites = ["Jessica", "Sarah", "Laura", "Alice", "Matilda", "Aria", "Rachel", "Katie", "Brooke"]
        switch self {
        case .openAI: return defaultVoice
        case .elevenLabs:
            return favourites.lazy.compactMap { name in voices.first { $0.name.hasPrefix(name) } }.first ?? voices.first
        case .cartesia:
            return voices.first { $0.id == defaultVoice.id } ?? voices.first
        }
    }

    var hasKey: Bool { storedKey() != nil }

    func storedKey(keychain: KeychainStore = KeychainStore()) -> String? {
        if let key = try? keychain.readChecked(account: keyAccount) { return key }
        guard self == .openAI else { return nil }
        return try? keychain.readChecked(account: RealtimeProvider(.openAI).keychainAccount)
    }

    func verify(key: String, session: URLSession = .shared) async throws -> [CloudVoiceOption] {
        guard let request = voicesRequest(key: key) else { return [] }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw NeuralSpeechError(message: status == 401 || status == 403
                ? "\(name) did not accept that key."
                : "\(name) answered with error \(status).")
        }
        return parseVoices(data)
    }
}

struct CloudVoiceOption: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let name: String
    var detail: String? = nil
}

struct CloudVoice: NeuralVoice {
    let provider: CloudVoiceProvider
    let voiceID: String
    let key: String
    var speed: Double = 1
    var session: URLSession = .shared

    var spellsNumbers: Bool { provider == .elevenLabs }

    func audio(for text: String, previous: String?) -> AsyncThrowingStream<Data, Error> {
        let request = provider.speechRequest(text: text, voiceID: voiceID, key: key, previous: previous, speed: speed)
        let provider = provider
        let session = session
        return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status) else {
                        var body = Data()
                        for try await byte in bytes.prefix(2_000) { body.append(byte) }
                        throw NeuralSpeechError(message: status == 401 || status == 403
                            ? "\(provider.name) did not accept the voice key."
                            : "\(provider.name) voice failed (\(status)).")
                    }
                    var chunk = Data()
                    chunk.reserveCapacity(4_800)
                    for try await byte in bytes {
                        chunk.append(byte)
                        if chunk.count >= 4_800 {
                            continuation.yield(chunk)
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                    if !chunk.isEmpty { continuation.yield(chunk) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
