// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mosemo",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CollectorCore", targets: ["CollectorCore"]),
        .library(name: "MosemoAPI", targets: ["MosemoAPI"]),
        .executable(name: "Mosemo", targets: ["MosemoApp"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-openapi-generator",
            exact: "1.13.0"
        ),
        .package(
            url: "https://github.com/apple/swift-openapi-runtime",
            exact: "1.12.0"
        ),
        .package(
            url: "https://github.com/apple/swift-openapi-urlsession",
            exact: "1.3.0"
        ),
        .package(
            url: "https://github.com/apple/swift-http-types",
            exact: "1.7.0"
        ),
    ],
    targets: [
        .target(
            name: "CollectorCore",
            path: "Sources/CollectorCore"
        ),
        .target(
            name: "MosemoAPI",
            dependencies: [
                .product(
                    name: "OpenAPIRuntime",
                    package: "swift-openapi-runtime"
                ),
                .product(
                    name: "OpenAPIURLSession",
                    package: "swift-openapi-urlsession"
                ),
                .product(
                    name: "HTTPTypes",
                    package: "swift-http-types"
                ),
            ],
            path: "Sources/MosemoAPI"
        ),
        .executableTarget(
            name: "MosemoApp",
            dependencies: ["CollectorCore", "MosemoAPI"],
            path: "Sources/MosemoApp"
        ),
        .testTarget(
            name: "CollectorCoreTests",
            dependencies: ["CollectorCore"],
            path: "Tests/CollectorCoreTests"
        ),
        .testTarget(
            name: "MosemoAPITests",
            dependencies: [
                "MosemoAPI",
                .product(
                    name: "OpenAPIRuntime",
                    package: "swift-openapi-runtime"
                ),
                .product(
                    name: "HTTPTypes",
                    package: "swift-http-types"
                ),
            ],
            path: "Tests/MosemoAPITests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
