// swift-tools-version: 5.9
import Foundation
import PackageDescription

/// Resolves the **static** `libzstd.a` used to read `.jsonl.zstd` DSH sessions.
///
/// Two constraints collide here:
/// 1. The shipped `.app` must not depend on a Homebrew dylib at runtime, so the
///    archive has to be linked statically (`.linkedLibrary("zstd")` would pull
///    in the dylib and break every machine without zstd installed).
/// 2. SwiftPM has no API for "link this specific archive", so the path can only
///    be passed through `unsafeFlags`.
///
/// The previous version hardcoded `/opt/homebrew/opt/zstd/lib/libzstd.a`, which
/// made the build fail on any Intel Mac, CI runner or fresh machine. Resolve the
/// path instead, and let `ZSTD_STATIC_LIB` override it for unusual setups.
///
/// Consequence to keep in mind: `unsafeFlags` means this package cannot be
/// consumed as a dependency by another package. That is acceptable — the
/// deliverable is an app, not a library.
func resolveZstdStaticLib() -> String {
    if let explicit = ProcessInfo.processInfo.environment["ZSTD_STATIC_LIB"], !explicit.isEmpty {
        return explicit
    }
    let candidates = [
        "/opt/homebrew/opt/zstd/lib/libzstd.a", // Homebrew, Apple Silicon
        "/usr/local/opt/zstd/lib/libzstd.a",    // Homebrew, Intel
        "/opt/local/lib/libzstd.a",             // MacPorts
    ]
    if let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
        return found
    }
    // Nothing found: return the most common location so the linker reports a
    // concrete missing file instead of the manifest failing silently.
    return "/opt/homebrew/opt/zstd/lib/libzstd.a"
}

let zstdStaticLib = resolveZstdStaticLib()

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
                .unsafeFlags([zstdStaticLib]),
            ]
        ),
        // Test runner: the pure-CommandLineTools toolchain has no XCTest /
        // Swift Testing, so tests run via `swift run PinnerTestRunner`.
        .executableTarget(
            name: "PinnerTestRunner",
            dependencies: ["CollectionBox"],
            path: "Sources/PinnerTestRunner",
            linkerSettings: [
                .unsafeFlags([zstdStaticLib]),
            ]
        ),
    ]
)
