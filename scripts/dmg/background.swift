import AppKit
import SwiftUI

enum Layout {
    static let size = CGSize(width: 640, height: 400)
    static let app = CGPoint(x: 170, y: 190)
    static let applications = CGPoint(x: 470, y: 190)
}

enum Palette {
    static let paper = Color(red: 0.953, green: 0.941, blue: 0.910)
    static let ink = Color(red: 0.047, green: 0.051, blue: 0.055)
    static let secondary = Color(red: 0.30, green: 0.33, blue: 0.31)
    static let fern = Color(red: 0.369, green: 0.859, blue: 0.506)
}

struct Grain: View {
    var body: some View {
        Canvas { context, size in
            var state: UInt64 = 0x9E3779B97F4A7C15
            func next() -> Double {
                state &+= 0x9E3779B97F4A7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
                z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
                return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
            }
            for _ in 0..<5200 {
                let rect = CGRect(x: next() * size.width, y: next() * size.height, width: 0.6, height: 0.6)
                context.fill(Path(ellipseIn: rect), with: .color(Palette.ink.opacity(0.05 + next() * 0.06)))
            }
        }
    }
}

struct InkArrow: View {
    let start: CGPoint
    let end: CGPoint
    let lift: CGFloat

    var body: some View {
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 - lift)
        let samples = InkStroke.sampled(through: [start, CGPoint(x: start.x + (mid.x - start.x) * 0.5, y: mid.y + lift * 0.3), mid, CGPoint(x: mid.x + (end.x - mid.x) * 0.55, y: mid.y + lift * 0.35), end], step: 1, jitter: 0, seed: 3)
        let widths = samples.indices.map { i -> CGFloat in
            let progress = CGFloat(i) / CGFloat(max(samples.count - 1, 1))
            return 1.4 + 2.2 * pow(sin(CGFloat.pi * min(progress * 1.15, 1)), 0.5)
        }
        let tail = samples[max(samples.count - 8, 0)]
        let angle = atan2(end.y - tail.y, end.x - tail.x)
        ZStack {
            InkStrokeShape(samples: samples, widths: widths)
            ForEach([CGFloat(-0.55), 0.62], id: \.self) { spread in
                let barb = CGPoint(x: end.x - 15 * cos(angle + spread), y: end.y - 15 * sin(angle + spread))
                let head = InkStroke.sampled(through: [barb, end], step: 1, jitter: 0, seed: 1)
                InkStrokeShape(samples: head, widths: head.indices.map { 1.6 + 1.6 * CGFloat($0) / CGFloat(max(head.count - 1, 1)) })
            }
        }
        .foregroundStyle(Palette.ink.opacity(0.88))
    }
}

struct NotchBezel: View {
    var body: some View {
        ZStack(alignment: .top) {
            Rectangle().fill(Palette.ink).frame(height: 7)
            UnevenRoundedRectangle(bottomLeadingRadius: 15, bottomTrailingRadius: 15, style: .continuous)
                .fill(Palette.ink)
                .frame(width: 176, height: 38)
            HStack(spacing: 7) {
                Capsule().fill(Palette.fern).frame(width: 6, height: 13)
                Capsule().fill(Palette.fern).frame(width: 6, height: 13)
            }
            .offset(y: 17)
        }
        .frame(width: Layout.size.width, alignment: .top)
    }
}

struct HomePath: View {
    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 476, y: 124))
            path.addQuadCurve(to: CGPoint(x: 414, y: 30), control: CGPoint(x: 492, y: 38))
        }
        .stroke(Palette.ink.opacity(0.5), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, dash: [0.1, 6]))
    }
}

struct Background: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Palette.paper
            RadialGradient(colors: [Color.white.opacity(0.55), .clear], center: .init(x: 0.5, y: 0.5), startRadius: 0, endRadius: 360)
            Grain()
            NotchBezel()
            HomePath()
            Text("then it lives up here")
                .font(.system(size: 11.5, design: .serif).italic())
                .foregroundStyle(Palette.secondary)
                .position(x: 548, y: 82)
            InkArrow(start: CGPoint(x: Layout.app.x + 72, y: Layout.app.y + 2), end: CGPoint(x: Layout.applications.x - 76, y: Layout.app.y + 2), lift: 22)
            VStack(spacing: 7) {
                Text("Drag Perry into Applications")
                    .font(.system(size: 22, weight: .semibold, design: .serif))
                    .foregroundStyle(Palette.ink)
                Text("Open it once, and Perry moves into your notch.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.secondary)
            }
            .frame(width: Layout.size.width)
            .padding(.top, 300)
        }
        .frame(width: Layout.size.width, height: Layout.size.height)
    }
}

@main
struct RenderBackground {
    @MainActor static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for scale in [1, 2] {
            let renderer = ImageRenderer(content: Background())
            renderer.scale = CGFloat(scale)
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try png.write(to: output.appendingPathComponent(scale == 1 ? "background.png" : "background@2x.png"))
        }
    }
}
