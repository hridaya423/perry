// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PerryOverlay",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PerryOverlay", targets: ["PerryOverlay"]),
    ],
    targets: [
        .target(
            name: "PerryOverlay",
            path: "Sources/PerryOverlay"
        ),
        .testTarget(name: "PerryOverlayTests", dependencies: ["PerryOverlay"], path: "Tests/PerryOverlayTests"),
    ]
)
