import AVFoundation
import PerryBrain
@testable import Perry
import XCTest

final class AnalyzerRecognitionTests: XCTestCase {
    func testSpokenFileTranscribesThroughTheTapPath() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("SpeechAnalyzer needs macOS 26") }
        guard let target = await AnalyzerRecognitionSession.prepare(locale: Locale(identifier: "en-US")) else {
            throw XCTSkip("SpeechTranscriber assets are not available on this Mac")
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: file) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", file.path, "I moved the meeting to Thursday and told Sam."]
        try say.run()
        say.waitUntilExit()

        let events = AsyncStream<DictationRecognitionEvent>.makeStream()
        let session = AnalyzerRecognitionSession(target: target, words: ["Sam"]) { events.continuation.yield($0) }
        for buffer in try Self.tapBuffers(from: file) {
            session.append(buffer)
        }
        session.endAudio()

        var final: (String, [SpokenWord])?
        var partials = 0
        for await event in events.stream {
            switch event {
            case .transcript(let text, isFinal: false, _): if !text.isEmpty { partials += 1 }
            case .transcript(let text, isFinal: true, let words): final = (text, words)
            case .failure(let error): XCTFail("\(error)")
            }
            if final != nil { break }
        }
        let (text, words) = try XCTUnwrap(final)
        let lowered = text.lowercased()
        XCTAssertTrue(lowered.contains("meeting"), text)
        XCTAssertTrue(lowered.contains("thursday"), text)
        XCTAssertTrue(lowered.contains("sam"), text)
        XCTAssertGreaterThan(partials, 0)
        XCTAssertFalse(words.isEmpty)
        XCTAssertEqual(words.map(\.start), words.map(\.start).sorted())
        print("ANALYZER:", text, words.map { "\($0.text)@\(String(format: "%.2f", $0.start))" })
    }

    private static func tapBuffers(from url: URL) throws -> [AVAudioPCMBuffer] {
        let file = try AVAudioFile(forReading: url)
        let tap = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let converter = try XCTUnwrap(AVAudioConverter(from: file.processingFormat, to: tap))
        let source = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: source)
        let whole = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: tap, frameCapacity: AVAudioFrameCount(Double(source.frameLength) * 48_000 / file.processingFormat.sampleRate) + 1024))
        var supplied = false
        try converter.convert(to: whole, error: nil) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true
            status.pointee = .haveData
            return source
        }
        var chunks: [AVAudioPCMBuffer] = []
        var offset: AVAudioFrameCount = 0
        while offset < whole.frameLength {
            let count = min(1024, whole.frameLength - offset)
            let chunk = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: tap, frameCapacity: count))
            chunk.frameLength = count
            memcpy(chunk.floatChannelData![0], whole.floatChannelData![0] + Int(offset), Int(count) * MemoryLayout<Float>.size)
            chunks.append(chunk)
            offset += count
        }
        return chunks
    }
}
