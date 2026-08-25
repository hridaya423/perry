// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PerryRuntimes",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PerryRuntimes", targets: ["PerryRuntimes"]),
    ],
    dependencies: [
        .package(path: "../PerryCore"),
    ],
    targets: [
        .target(
            name: "PerryRuntimes",
            dependencies: [
                .product(name: "PerryCore", package: "PerryCore"),
            ],
            path: "Sources/PerryRuntimes"
        ),
        .executableTarget(
            name: "perry-demo",
            dependencies: ["PerryRuntimes", .product(name: "PerryCore", package: "PerryCore")],
            path: "Sources/perry-demo"
        ),
        .testTarget(name: "PerryRuntimesTests", dependencies: ["PerryRuntimes"], path: "Tests/PerryRuntimesTests"),
    ]
)
