// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CollectionBox",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CollectionBox", targets: ["CollectionBox"]),
        .executable(name: "CollectionBoxApp", targets: ["CollectionBoxApp"]),
    ],
    targets: [
        .target(
            name: "CollectionBox",
            path: "Sources/CollectionBox"
        ),
        .executableTarget(
            name: "CollectionBoxApp",
            dependencies: ["CollectionBox"],
            path: "Sources/CollectionBoxApp",
            exclude: ["Assets.xcassets", "Resources"],
            linkerSettings: [
                // DSH session files are zstd-compressed; link Homebrew libzstd.
                .unsafeFlags(["-L/opt/homebrew/lib", "-lzstd"]),
            ]
        ),
        // Test runner: the pure-CommandLineTools toolchain has no XCTest /
        // Swift Testing, so tests run via `swift run PinnerTestRunner`.
        .executableTarget(
            name: "PinnerTestRunner",
            dependencies: ["CollectionBox"],
            path: "Sources/PinnerTestRunner",
            linkerSettings: [
                .unsafeFlags(["-L/opt/homebrew/lib", "-lzstd"]),
            ]
        ),
    ]
)
