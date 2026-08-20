// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "JBar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "JBar", targets: ["JBar"]),
        .library(name: "JBarCore", targets: ["JBarCore"]),
    ],
    targets: [
        // Pure-logic core: indexer, fuzzy matcher, ranking, config. No AppKit UI, fully unit-testable.
        .target(name: "JBarCore", path: "Sources/JBarCore"),
        // The AppKit app: hotkey, panel, menubar, launching.
        .executableTarget(name: "JBar", dependencies: ["JBarCore"], path: "Sources/JBar"),
        .testTarget(name: "JBarCoreTests", dependencies: ["JBarCore"], path: "Tests/JBarCoreTests"),
    ]
)
