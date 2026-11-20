// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DesignParity",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "parity", targets: ["parity"]),
        .library(name: "ParityCore", targets: ["ParityCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        // Image and text comparison. Pure Swift: no Apple frameworks, so it builds and tests anywhere.
        .target(name: "ParityCore"),
        // Figma REST API: frame images and text layers.
        .target(name: "ParityFigma", dependencies: ["ParityCore"]),
        // macOS adapters: PNG via ImageIO, text recognition via Vision, the iOS Simulator via simctl.
        .target(name: "ParityApple", dependencies: ["ParityCore"]),
        // Model Context Protocol server (JSON-RPC over stdio) so AI coding agents can call the checks.
        .target(name: "ParityMCP"),
        .executableTarget(name: "parity", dependencies: [
            "ParityCore", "ParityFigma", "ParityApple", "ParityMCP",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        .testTarget(name: "ParityCoreTests", dependencies: ["ParityCore"]),
        .testTarget(name: "ParityFigmaTests", dependencies: ["ParityFigma"]),
        .testTarget(name: "ParityMCPTests", dependencies: ["ParityMCP"]),
        // Runs on macOS only (ImageIO, Vision); compiles to nothing elsewhere.
        .testTarget(name: "ParityAppleTests", dependencies: ["ParityApple", "ParityCore"]),
    ]
)
