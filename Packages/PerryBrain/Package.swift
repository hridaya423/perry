// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PerryBrain",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PerryBrain", targets: ["PerryBrain"]),
        .executable(name: "perry-brain-smoke", targets: ["perry-brain-smoke"]),
    ],
    dependencies: [
        .package(path: "../PerryCore"),
    ],
    targets: [
        .target(
            name: "PerryBrain",
            dependencies: [.product(name: "PerryCore", package: "PerryCore")],
            path: "Sources/PerryBrain"
        ),
        .executableTarget(
            name: "perry-brain-smoke",
            dependencies: ["PerryBrain"],
            path: "Sources/perry-brain-smoke"
        ),
        .testTarget(
            name: "PerryBrainTests",
            dependencies: ["PerryBrain"],
            path: "Tests/PerryBrainTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
