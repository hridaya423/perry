// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PerryCapture",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PerryCapture", targets: ["PerryCapture"]),
    ],
    dependencies: [
        .package(path: "../PerryCore"),
    ],
    targets: [
        .target(
            name: "PerryCapture",
            dependencies: [
                .product(name: "PerryCore", package: "PerryCore"),
            ],
            path: "Sources/PerryCapture"
        ),
        .testTarget(name: "PerryCaptureTests", dependencies: ["PerryCapture"], path: "Tests/PerryCaptureTests"),
    ]
)
