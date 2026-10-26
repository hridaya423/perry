import AVFoundation
import Foundation

struct Fixture: Encodable {
    struct Transcript: Encodable {
        let t: Double
        let text: String
        let lastWordEnd: Double
    }
    let name: String
    let noise: String
    let frames: [[Double]]
    let transcripts: [Transcript]
    let speechEnd: Double?
}

let arguments = CommandLine.arguments
guard arguments.count == 7 else {
    FileHandle.standardError.write("usage: turn-fixture.swift <name> <audio.aiff|-> <phrases a|b|c> <noise none|fan> <snr-db> <out.json>\n".data(using: .utf8)!)
    exit(2)
}
let name = arguments[1], audioPath = arguments[2], phrases = arguments[3].isEmpty ? [] : arguments[3].components(separatedBy: "|")
let noiseKind = arguments[4], snr = Double(arguments[5])!, output = arguments[6]
let rate = 16_000.0, frame = Int(rate * 0.02), lead = Int(rate * 0.6), tail = Int(rate * 9.5)

var speech: [Float] = []
if audioPath != "-" {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: audioPath))
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
    let converter = AVAudioConverter(from: file.processingFormat, to: format)!
    let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: source)
    let capacity = AVAudioFrameCount(Double(file.length) * rate / file.processingFormat.sampleRate) + 1024
    let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
    var fed = false
    _ = converter.convert(to: converted, error: nil) { _, status in
        if fed { status.pointee = .endOfStream; return nil }
        fed = true
        status.pointee = .haveData
        return source
    }
    speech = Array(UnsafeBufferPointer(start: converted.floatChannelData![0], count: Int(converted.frameLength)))
}
var signal = [Float](repeating: 0, count: lead) + speech + [Float](repeating: 0, count: tail)

let voiced = speech.filter { abs($0) > 0.01 }
let speechRMS = voiced.isEmpty ? 0.05 : sqrt(voiced.reduce(0) { $0 + Double($1 * $1) } / Double(voiced.count))
let noiseRMS = noiseKind == "fan" ? speechRMS / pow(10, snr / 20) : 0.0004
var state: UInt64 = 0x9E3779B97F4A7C15 &+ UInt64(name.utf8.reduce(0) { $0 &* 31 &+ UInt64($1) })
var low = 0.0
for index in signal.indices {
    state = state &* 6364136223846793005 &+ 1442695040888963407
    let white = Double(Int64(bitPattern: state >> 11) % 2_000_000) / 1_000_000 - 1
    low += (white - low) * (noiseKind == "fan" ? 0.15 : 1)
    signal[index] += Float(low * noiseRMS * (noiseKind == "fan" ? 4.2 : 1.7))
}

var frames: [[Double]] = []
for start in stride(from: 0, to: signal.count - frame, by: frame) {
    let slice = signal[start..<start + frame]
    let rms = sqrt(slice.reduce(0) { $0 + Double($1 * $1) } / Double(frame))
    frames.append([Double(start + frame) / rate, (rms * 1e6).rounded() / 1e6])
}

let speechFrames = Set(stride(from: 0, to: speech.count - frame, by: frame).compactMap { start -> Int? in
    let slice = speech[start..<start + frame]
    let rms = sqrt(slice.reduce(0) { $0 + Double($1 * $1) } / Double(frame))
    return rms > 0.006 ? (start + lead) / frame : nil
})
var segments: [(Double, Double)] = []
for index in speechFrames.sorted() {
    let begin = Double(index) * 0.02, end = Double(index + 1) * 0.02
    if let last = segments.last, begin - last.1 < 0.3 {
        segments[segments.count - 1].1 = end
    } else {
        segments.append((begin, end))
    }
}
guard segments.count == phrases.count else {
    FileHandle.standardError.write("\(name): \(segments.count) segments \(segments) for \(phrases.count) phrases\n".data(using: .utf8)!)
    exit(1)
}
var transcripts: [Fixture.Transcript] = []
for (index, segment) in segments.enumerated() {
    let words = phrases[index].split(separator: " ")
    let spoken = phrases[..<index].joined(separator: " ")
    if words.count > 2 {
        let half = words.prefix(words.count / 2).joined(separator: " ")
        let mid = segment.0 + (segment.1 - segment.0) / 2
        transcripts.append(.init(t: mid + 0.25, text: [spoken, half].filter { !$0.isEmpty }.joined(separator: " "), lastWordEnd: mid))
    }
    transcripts.append(.init(t: segment.1 + 0.25, text: phrases[...index].joined(separator: " "), lastWordEnd: segment.1))
}
let fixture = Fixture(name: name, noise: noiseKind, frames: frames, transcripts: transcripts, speechEnd: segments.last?.1)
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
try encoder.encode(fixture).write(to: URL(fileURLWithPath: output))
print("\(name): \(segments.count) segments, speech ends \(segments.last?.1 ?? 0)")
