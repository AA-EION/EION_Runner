// swift-tools-version: 6.2
//
// Runner Forge — macOS.
//
// Deployment target macOS 26 (Tahoe). Swift 6 language mode, Swift Concurrency
// throughout (async/await and structured tasks — no completion handlers), and
// the Observation framework (@Observable, never ObservableObject).
//
// The tools version is 6.2, not 6.0, because `.macOS(.v26)` was introduced in
// PackageDescription 6.2. With tools-version 6.0 SwiftPM compiles this manifest
// against the 6.0 PackageDescription and rejects `.v26` as unavailable, even on
// a Swift 6.3 toolchain — the toolchain is not what gates it, the declared tools
// version is.
//
// Built as a library plus a thin executable so the logic is testable: Swift
// Testing cannot import an executable target, which is why the @main entry point
// is the only file that lives outside Sources/RunnerForge. The .app bundle is
// assembled by build.sh from Sources/RunnerForge/Resources.

import PackageDescription

let package = Package(
    name: "RunnerForge",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .executable(name: "RunnerForge", targets: ["RunnerForgeApp"]),
        .library(name: "RunnerForgeKit", targets: ["RunnerForge"]),
    ],
    targets: [
        // Everything that is not the @main entry point. Tests import this.
        .target(
            name: "RunnerForge",
            path: "Sources/RunnerForge",
            // Info.plist and the entitlements are inputs to build.sh, not SwiftPM
            // resources: SwiftPM does not build .app bundles and would only warn
            // about files it has no rule for.
            exclude: ["Resources"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .executableTarget(
            name: "RunnerForgeApp",
            dependencies: ["RunnerForge"],
            path: "Sources/RunnerForgeApp",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "RunnerForgeTests",
            dependencies: ["RunnerForge"],
            path: "Tests/RunnerForgeTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
