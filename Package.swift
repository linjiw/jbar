// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "JBar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "JBar", targets: ["JBar"]),
        .library(name: "JBarCore", targets: ["JBarCore"]),
        .library(name: "JBarActions", targets: ["JBarActions"]),
    ],
    targets: [
        // Pure-logic core: indexer, fuzzy matcher, ranking, config. No AppKit UI, fully unit-testable.
        .target(name: "JBarCore", path: "Sources/JBarCore"),
        // Intent parsing plus the narrow Codex app-server client. It has no third-party dependencies;
        // process launch, protocol validation, and network/tool denial stay auditable in one target.
        .target(name: "JBarActions", path: "Sources/JBarActions"),
        // The AppKit app as a LIBRARY so tests can import it (an executable target cannot be
        // @testable imported, which is why the UI had no coverage).
        .target(name: "JBarApp", dependencies: ["JBarCore", "JBarActions"], path: "Sources/JBarApp"),
        // Thin executable shim: `main.swift` only calls `runJBar()`.
        .executableTarget(name: "JBar", dependencies: ["JBarApp"], path: "Sources/JBar"),
        .testTarget(name: "JBarCoreTests", dependencies: ["JBarCore"], path: "Tests/JBarCoreTests"),
        .testTarget(name: "JBarActionsTests", dependencies: ["JBarActions"], path: "Tests/JBarActionsTests"),
        .testTarget(name: "JBarAppTests", dependencies: ["JBarApp", "JBarActions"], path: "Tests/JBarAppTests"),
    ]
)
