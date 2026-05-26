// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CollectionBox",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CollectionBox", targets: ["CollectionBox"]),
        .executable(name: "CollectionBoxApp", targets: ["CollectionBoxApp"]),
        .executable(name: "CollectionBoxTests", targets: ["CollectionBoxTests"]),
    ],
    targets: [
        .target(
            name: "CollectionBox",
            path: "Sources/CollectionBox"
        ),
        .executableTarget(
            name: "CollectionBoxApp",
            dependencies: ["CollectionBox"],
            path: "Sources/CollectionBoxApp"
        ),
        .executableTarget(
            name: "CollectionBoxTests",
            dependencies: ["CollectionBox"],
            path: "Tests/CollectionBoxTests"
        ),
    ]
)
