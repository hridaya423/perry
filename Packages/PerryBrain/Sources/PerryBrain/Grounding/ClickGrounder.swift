import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import PerryCore
import UniformTypeIdentifiers

/// Finds a described target in a window screenshot with a local grounding
/// model (Holo-3.1, GUI-Owl-1.5) served over an OpenAI-compatible endpoint.
/// A first pass reads the window at about 900 image tokens. Two sampled
/// passes check it; when they scatter, one pass at up to 2000 tokens re-reads
/// the half of the window around the first answer.
public struct ClickGrounder: Sendable {
    public struct Endpoint: Sendable {
        public var baseURL: URL
        public var apiKey: String?

        public init(baseURL: URL, apiKey: String?) {
            self.baseURL = baseURL
            self.apiKey = apiKey
        }
    }

    public struct Located: Equatable, Sendable {
        public var point: CGPoint
        public var confident: Bool
    }

    public enum GroundingError: Error, Equatable, LocalizedError {
        case unreadableScreenshot
        case noPoint(String)

        public var errorDescription: String? {
            switch self {
            case .unreadableScreenshot: "The screenshot could not be read."
            case .noPoint(let reply): "The local model gave no click point: \(reply.prefix(120))"
            }
        }
    }

    static let firstPassPixels = 1280 * 720
    static let zoomPassPixels = 1920 * 1088
    static let samples = 2
    static let agreement = 0.03
    static let zoomFraction = 0.5

    private let endpoint: @Sendable () async throws -> Endpoint
    private let send: @Sendable (URLRequest) async throws -> Data

    public init(
        endpoint: @escaping @Sendable () async throws -> Endpoint,
        send: @escaping @Sendable (URLRequest) async throws -> Data = ClickGrounder.post
    ) {
        self.endpoint = endpoint
        self.send = send
    }

    /// Returns the target in window points (origin at the window's top left).
    /// When `accepts` approves the first point, the check passes are skipped.
    public func locate(
        _ description: String, screenshot: Data, windowSize: CGSize,
        accepts: (@Sendable (CGPoint) -> Bool)? = nil
    ) async throws -> Located {
        guard let image = Self.decode(screenshot) else { throw GroundingError.unreadableScreenshot }
        let server = try await endpoint()
        let whole = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let overview = Self.jpeg(image, region: whole, maxPixels: Self.firstPassPixels) else { throw GroundingError.unreadableScreenshot }
        let first = try await ask(description, jpeg: overview, temperature: 0, server: server)
        if accepts?(Self.windowPoint(first, in: windowSize)) == true {
            return Located(point: Self.windowPoint(first, in: windowSize), confident: true)
        }
        var points = [first]
        for _ in 0..<Self.samples {
            points.append(try await ask(description, jpeg: overview, temperature: 0.7, server: server))
        }
        if Self.spread(points) <= Self.agreement {
            return Located(point: Self.windowPoint(first, in: windowSize), confident: true)
        }
        let region = Self.zoomRegion(around: first, imageSize: CGSize(width: image.width, height: image.height))
        guard let detail = Self.jpeg(image, region: region, maxPixels: Self.zoomPassPixels) else { throw GroundingError.unreadableScreenshot }
        let zoomed = try await ask(description, jpeg: detail, temperature: 0, server: server)
        let mapped = CGPoint(
            x: (region.minX + zoomed.x * region.width) / CGFloat(image.width),
            y: (region.minY + zoomed.y * region.height) / CGFloat(image.height)
        )
        return Located(point: Self.windowPoint(mapped, in: windowSize), confident: false)
    }

    private func ask(_ description: String, jpeg: Data, temperature: Double, server: Endpoint) async throws -> CGPoint {
        let body = Self.requestBody(description: description, jpeg: jpeg, temperature: temperature)
        var request = URLRequest(url: server.baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = server.apiKey { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try body.data()
        var lastReply = ""
        for _ in 0..<2 {
            let reply = try JSONValue(parsing: try await send(request))
            lastReply = reply["choices"]?.arrayValue?.first?["message"]?["content"]?.stringValue ?? ""
            if let point = Self.parsePoint(lastReply) { return point }
        }
        throw GroundingError.noPoint(lastReply)
    }

    static let systemPrompt = """
        You control a Mac. Reply with one JSON object only: {"action": "click", "x": int, "y": int}. \
        x and y are relative coordinates from 0 to 1000, where (0,0) is the top left and (1000,1000) the bottom right.
        """

    static func requestBody(description: String, jpeg: Data, temperature: Double) -> JSONValue {
        let integer: JSONValue = .object(["type": .string("integer")])
        return .object([
            "model": .string("local"),
            "temperature": .number(temperature),
            "max_tokens": .number(40),
            "chat_template_kwargs": .object(["enable_thinking": .bool(false)]),
            "response_format": .object([
                "type": .string("json_schema"),
                "json_schema": .object([
                    "name": .string("click"),
                    "schema": .object([
                        "type": .string("object"),
                        "properties": .object(["action": .object(["const": .string("click")]), "x": integer, "y": integer]),
                        "required": .array([.string("action"), .string("x"), .string("y")]),
                        "additionalProperties": .bool(false),
                    ]),
                ]),
            ]),
            "messages": .array([
                .object(["role": .string("system"), "content": .string(systemPrompt)]),
                .object(["role": .string("user"), "content": .array([
                    .object(["type": .string("text"), "text": .string("Goal: \(description)")]),
                    .object(["type": .string("image_url"), "image_url": .object([
                        "url": .string("data:image/jpeg;base64,\(jpeg.base64EncodedString())"),
                    ])]),
                ])]),
            ]),
        ])
    }

    static func parsePoint(_ text: String) -> CGPoint? {
        func number(_ key: String) -> Double? {
            guard let match = text.firstMatch(of: try! Regex("\"\(key)\"\\s*:\\s*(-?[0-9]+(?:\\.[0-9]+)?)")),
                  let value = match.output[1].substring.flatMap({ Double($0) }), value.isFinite else { return nil }
            return min(max(value, 0), 1000) / 1000
        }
        guard let x = number("x"), let y = number("y") else { return nil }
        return CGPoint(x: x, y: y)
    }

    static func spread(_ points: [CGPoint]) -> Double {
        guard let first = points.first else { return 0 }
        return points.map { max(abs($0.x - first.x), abs($0.y - first.y)) }.max() ?? 0
    }

    static func zoomRegion(around center: CGPoint, imageSize: CGSize) -> CGRect {
        let width = imageSize.width * zoomFraction
        let height = imageSize.height * zoomFraction
        let x = min(max(center.x * imageSize.width - width / 2, 0), imageSize.width - width)
        let y = min(max(center.y * imageSize.height - height / 2, 0), imageSize.height - height)
        return CGRect(x: x, y: y, width: width, height: height).integral
    }

    static let snappableRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXMenuItem",
        "AXMenuBarItem", "AXLink", "AXTab", "AXTextField", "AXSearchField", "AXComboBox",
        "AXDisclosureTriangle", "AXIncrementor", "AXSlider", "AXSegment", "AXCell", "AXRow",
    ]

    /// The smallest control containing `point` (screen coordinates), when it
    /// is a clickable role and covers under a quarter of the window.
    public static func snapTarget(_ point: CGPoint, elements: [ObservedElement], window: CGRect) -> ObservedElement? {
        let limit = window.width * window.height / 4
        return elements
            .filter { snappableRoles.contains($0.role) && $0.frame.contains(point) && $0.frame.width * $0.frame.height < limit }
            .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    static func windowPoint(_ fraction: CGPoint, in windowSize: CGSize) -> CGPoint {
        CGPoint(x: fraction.x * windowSize.width, y: fraction.y * windowSize.height)
    }

    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static let rendering = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    static func jpeg(_ image: CGImage, region: CGRect, maxPixels: Int) -> Data? {
        guard let cropped = image.cropping(to: region) else { return nil }
        let scale = min(1, (Double(maxPixels) / Double(cropped.width * cropped.height)).squareRoot())
        let width = max(1, Int((Double(cropped.width) * scale).rounded()))
        let height = max(1, Int((Double(cropped.height) * scale).rounded()))
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = CIImage(cgImage: cropped).clampedToExtent()
        filter.scale = Float(Double(height) / Double(cropped.height))
        filter.aspectRatio = Float((Double(width) / Double(cropped.width)) / (Double(height) / Double(cropped.height)))
        guard let output = filter.outputImage,
              let scaled = rendering.createCGImage(output, from: CGRect(x: 0, y: 0, width: width, height: height)) else { return nil }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return encoded as Data
    }

    public static let post: @Sendable (URLRequest) async throws -> Data = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
