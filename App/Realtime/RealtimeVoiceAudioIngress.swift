import AVFoundation
import Foundation
import PerryCore

struct RealtimeVoiceAudioPacket: Equatable, Sendable {
    let data: Data
    let sessionID: Int
    let utteranceGeneration: Int
}

final class RealtimeVoiceAudioIngress: @unchecked Sendable {
    let stream: AsyncStream<RealtimeVoiceAudioPacket>

    private let continuation: AsyncStream<RealtimeVoiceAudioPacket>.Continuation
    private let lock = NSLock()
    private var overflowed = false

    init(capacity: Int) {
        let pair = AsyncStream<RealtimeVoiceAudioPacket>.makeStream(
            bufferingPolicy: .bufferingNewest(max(capacity, 1))
        )
        stream = pair.stream
        continuation = pair.continuation
    }

    func yield(_ packet: RealtimeVoiceAudioPacket) {
        guard case .dropped = continuation.yield(packet) else { return }
        lock.lock()
        overflowed = true
        lock.unlock()
    }

    func consumeOverflow() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let value = overflowed
        overflowed = false
        return value
    }

    func finish() {
        continuation.finish()
    }
}
