// scripts/lab/sfstt-timestamps.swift, Phase 0 deixis spike.
// Transcribes an audio file with SFSpeechRecognizer and prints per-word
// timestamps, proving SFTranscriptionSegment.timestamp is populated.
// Usage: say -o /tmp/spike.aiff "what does this button do" && \
//        swift scripts/lab/sfstt-timestamps.swift /tmp/spike.aiff
import Speech
import Foundation

guard CommandLine.arguments.count > 1 else {
    fputs("usage: swift sfstt-timestamps.swift <audio file>\n", stderr)
    exit(2)
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])

let sema = DispatchSemaphore(value: 0)
var authed = false
SFSpeechRecognizer.requestAuthorization { status in
    authed = (status == .authorized)
    sema.signal()
}
sema.wait()
guard authed else { print("{\"error\":\"speech recognition not authorized\"}"); exit(1) }

guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
    print("{\"error\":\"no en-US recognizer\"}")
    exit(1)
}

let request = SFSpeechURLRecognitionRequest(url: url)
request.shouldReportPartialResults = false
if #available(macOS 13, *) { request.addsPunctuation = true }

let done = DispatchSemaphore(value: 0)
var out: [[String: Any]] = []
var failure = ""
recognizer.recognitionTask(with: request) { result, error in
    if let result {
        for segment in result.bestTranscription.segments {
            out.append([
                "word": segment.substring,
                "timestamp": segment.timestamp,
                "duration": segment.duration,
            ])
        }
        if result.isFinal { done.signal() }
    }
    if let error {
        failure = error.localizedDescription
        done.signal()
    }
}
_ = done.wait(timeout: .now() + 60)

if !failure.isEmpty { print("{\"error\":\(jsonString(failure))}"); exit(1) }
let timed = out.filter { ($0["timestamp"] as? Double ?? 0) > 0 || ($0["duration"] as? Double ?? 0) > 0 }
print(String(data: try! JSONSerialization.data(withJSONObject: [
    "words": out.count,
    "with_timing": timed.count,
    "segments": out,
]), encoding: .utf8)!)

func jsonString(_ s: String) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: s), encoding: .utf8)!
}
