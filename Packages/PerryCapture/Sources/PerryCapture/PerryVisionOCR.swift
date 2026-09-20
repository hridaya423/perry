import Foundation
import ImageIO
import Vision

public struct PerryTextObservation: Equatable, Sendable {
    public let text: String
    public let confidence: Float
    public let normalizedBoundingBox: CGRect

    public init(text: String, confidence: Float, normalizedBoundingBox: CGRect) {
        self.text = text
        self.confidence = confidence
        self.normalizedBoundingBox = normalizedBoundingBox
    }

    public func screenRect(in capture: PerryScreenCapture) -> CGRect {
        capture.screenRect(forVisionBoundingBox: normalizedBoundingBox)
    }
}

public enum PerryVisionTextRecognizer {
    public static func recognizeText(in capture: PerryScreenCapture) throws -> [PerryTextObservation] {
        try recognizeText(in: capture.imageData)
    }

    public static func recognizeText(in imageData: Data) throws -> [PerryTextObservation] {
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw PerryCaptureError.invalidImageData
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        do {
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try handler.perform([request])
        } catch {
            throw PerryCaptureError.visionRecognitionFailed(error.localizedDescription)
        }

        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first,
                  !candidate.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return PerryTextObservation(
                text: candidate.string,
                confidence: candidate.confidence,
                normalizedBoundingBox: observation.boundingBox
            )
        }
    }
}

public struct PerryTextMatch: Equatable, Sendable {
    public let target: String
    public let observation: PerryTextObservation

    public init(target: String, observation: PerryTextObservation) {
        self.target = target
        self.observation = observation
    }

    public func screenRect(in capture: PerryScreenCapture) -> CGRect {
        observation.screenRect(in: capture)
    }
}

public enum PerryTextTargetMatcher {
    public enum Mode: Equatable, Sendable {
        case exact
        case contains
    }

    public static func firstMatch(
        target: String,
        in observations: [PerryTextObservation],
        mode: Mode = .exact,
        minimumConfidence: Float = 0
    ) -> PerryTextMatch? {
        let normalizedTarget = normalize(target)
        guard !normalizedTarget.isEmpty else { return nil }

        let candidates = observations.enumerated().filter { _, observation in
            guard observation.confidence >= minimumConfidence else { return false }
            return matches(normalize(observation.text), target: normalizedTarget, mode: mode)
        }

        guard let candidate = candidates.sorted(by: { left, right in
            if left.element.confidence == right.element.confidence {
                return left.offset < right.offset
            }
            return left.element.confidence > right.element.confidence
        }).first else {
            return nil
        }

        return PerryTextMatch(target: target, observation: candidate.element)
    }

    private static func matches(_ observation: String, target: String, mode: Mode) -> Bool {
        switch mode {
        case .exact:
            return observation == target
        case .contains:
            return observation == target
                || observation.hasPrefix("\(target) ")
                || observation.hasSuffix(" \(target)")
                || observation.contains(" \(target) ")
        }
    }

    private static func normalize(_ value: String) -> String {
        value
            .lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
