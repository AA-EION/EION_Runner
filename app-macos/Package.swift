// swift-tools-version: 6.0
//
// Runner Forge — macOS.
//
// Deployment target macOS 26 (Tahoe). Swift 6 language mode, Swift Concurrency
// throughout (async/await and structured tasks — no completion handlers), and
// the Observation framework (@Observable, never ObservableObject).
//
// Built as a library plus a thin executable so the logic is testable: Swift
// Testing cannot import an executable target. The .app bundle, its Info.plist
// and its entitlements are assembled by build.sh from ../Resources; they are
// not SwiftPM resources, because SwiftPM does not build .app bundles.

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
