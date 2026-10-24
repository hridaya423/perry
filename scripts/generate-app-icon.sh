#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)"
OVERLAY="${REPO_ROOT}/Packages/PerryOverlay/Sources/PerryOverlay"
CATALOG="${REPO_ROOT}/App/Assets.xcassets"
ICONSET="${CATALOG}/AppIcon.appiconset"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

cat > "${WORK}/main.swift" <<'SWIFT'
import AppKit
import SwiftUI

struct AppIcon: View {
    var body: some View {
        let tile = RoundedRectangle(cornerRadius: 185.4, style: .continuous)
        ZStack {
            tile
                .fill(LinearGradient(colors: [Color(red: 0.225, green: 0.22, blue: 0.215), Color(red: 0.045, green: 0.05, blue: 0.055)], startPoint: .top, endPoint: .bottom))
                .overlay(tile.strokeBorder(LinearGradient(colors: [.white.opacity(0.3), .clear], startPoint: .top, endPoint: .center), lineWidth: 3))
                .shadow(color: .black.opacity(0.32), radius: 14, y: 10)
                .frame(width: 824, height: 824)
            PerryCharacterView(pose: PerryCharacterPose(), size: 655)
                .frame(width: 655, height: 655)
                .offset(x: 6, y: 30)
        }
        .frame(width: 1024, height: 1024)
    }
}

@main
struct Render {
    @MainActor
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        var images: [String] = []
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
                let renderer = ImageRenderer(content: AppIcon())
                renderer.scale = CGFloat(points * scale) / 1024
                let png = NSBitmapImageRep(cgImage: renderer.cgImage!).representation(using: .png, properties: [:])!
                try png.write(to: directory.appendingPathComponent(name))
                images.append(#"{ "filename" : "\#(name)", "idiom" : "mac", "scale" : "\#(scale)x", "size" : "\#(points)x\#(points)" }"#)
            }
        }
        let contents = "{\n  \"images\" : [\n    \(images.joined(separator: ",\n    "))\n  ],\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n"
        try contents.write(to: directory.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
    }
}
SWIFT

swiftc -parse-as-library -O -o "${WORK}/render" "${OVERLAY}"/*.swift "${WORK}/main.swift"
mkdir -p "${ICONSET}"
printf '{\n  "info" : { "author" : "xcode", "version" : 1 }\n}\n' > "${CATALOG}/Contents.json"
"${WORK}/render" "${ICONSET}"
