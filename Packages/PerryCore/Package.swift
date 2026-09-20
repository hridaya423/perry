// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PerryCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PerryCore", targets: ["PerryCore"]),
    ],
    targets: [
        .target(name: "PerryCore", path: "Sources/PerryCore"),
        .testTarget(name: "PerryCoreTests", dependencies: ["PerryCore"], path: "Tests/PerryCoreTests"),
    ]
)
