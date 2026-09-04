// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mosemo",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CollectorCore", targets: ["CollectorCore"]),
        .executable(name: "Mosemo", targets: ["MosemoApp"]),
    ],
    targets: [
        .target(
            name: "CollectorCore",
            path: "Sources/CollectorCore"
        ),
        .executableTarget(
            name: "MosemoApp",
            dependencies: ["CollectorCore"],
            path: "Sources/MosemoApp"
        ),
        .testTarget(
            name: "CollectorCoreTests",
            dependencies: ["CollectorCore"],
            path: "Tests/CollectorCoreTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
