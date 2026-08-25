// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PerryCapture",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PerryCapture", targets: ["PerryCapture"]),
    ],
    targets: [
        .target(name: "PerryCapture", path: "Sources/PerryCapture"),
        .testTarget(name: "PerryCaptureTests", dependencies: ["PerryCapture"], path: "Tests/PerryCaptureTests"),
    ]
)
