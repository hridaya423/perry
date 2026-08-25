// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PerryCore",
    products: [
        .library(name: "PerryCore", targets: ["PerryCore"]),
    ],
    targets: [
        .target(name: "PerryCore", path: "Sources/PerryCore"),
        .testTarget(name: "PerryCoreTests", dependencies: ["PerryCore"], path: "Tests/PerryCoreTests"),
    ]
)
