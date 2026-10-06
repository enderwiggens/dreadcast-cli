// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "dreadcast",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "dread", targets: ["dread"]),
        .library(name: "DreadcastKit", targets: ["DreadcastKit"]),
        .library(name: "DreadTerminal", targets: ["DreadTerminal"])
    ],
    targets: [
        // Providers, decoders and domain models. No terminal or UI code.
        .target(name: "DreadcastKit"),
        // Terminal capability detection, styling, rasters and image protocols.
        .target(name: "DreadTerminal"),
        // Commands, configuration, caching and output formatting.
        .target(name: "DreadCLI", dependencies: ["DreadcastKit", "DreadTerminal"]),
        .executableTarget(name: "dread", dependencies: ["DreadCLI"]),
        .testTarget(name: "DreadcastKitTests", dependencies: ["DreadcastKit"]),
        .testTarget(name: "DreadTerminalTests", dependencies: ["DreadTerminal", "DreadcastKit"]),
        .testTarget(name: "DreadCLITests", dependencies: ["DreadCLI", "DreadcastKit", "DreadTerminal"])
    ]
)
