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
        // The AppKit app as a LIBRARY so tests can import it (an executable target cannot be
        // @testable imported, which is why the UI had no coverage).
        .target(name: "JBarApp", dependencies: ["JBarCore"], path: "Sources/JBarApp"),
        // Thin executable shim: `main.swift` only calls `runJBar()`.
        .executableTarget(name: "JBar", dependencies: ["JBarApp"], path: "Sources/JBar"),
        .testTarget(name: "JBarCoreTests", dependencies: ["JBarCore"], path: "Tests/JBarCoreTests"),
        .testTarget(name: "JBarAppTests", dependencies: ["JBarApp"], path: "Tests/JBarAppTests"),
    ]
)
