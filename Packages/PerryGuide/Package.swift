// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PerryGuide",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PerryGuide", targets: ["PerryGuide"]),
    ],
    dependencies: [
        .package(path: "../PerryCore"),
        .package(path: "../PerryOverlay"),
        .package(path: "../PerryRuntimes"),
    ],
    targets: [
        .target(
            name: "PerryGuide",
            dependencies: [
                .product(name: "PerryCore", package: "PerryCore"),
                .product(name: "PerryOverlay", package: "PerryOverlay"),
                .product(name: "PerryRuntimes", package: "PerryRuntimes"),
            ],
            path: "Sources/PerryGuide",
            resources: [.process("Resources")]
        ),
        .testTarget(name: "PerryGuideTests", dependencies: ["PerryGuide"], path: "Tests/PerryGuideTests"),
    ]
)
