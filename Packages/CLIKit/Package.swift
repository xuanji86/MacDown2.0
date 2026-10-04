// swift-tools-version: 6.2
import PackageDescription

// Everything the `macdown2` command does, as a library so `swift test` covers it (the CLI target is a one-line main.swift).
// Foundation only: no AppKit, so the tool never gets a Dock icon. Depends on MarkdownCore + WebAssets, never on an *Extension module.
let package = Package(
    name: "CLIKit",
    platforms: [.macOS(.v26)],
    products: [.library(name: "CLIKit", targets: ["CLIKit"])],
    dependencies: [.package(path: "../MarkdownCore"), .package(path: "../WebAssets")],
    targets: [
        .target(name: "CLIKit", dependencies: ["MarkdownCore", "WebAssets"]),
        .testTarget(name: "CLIKitTests", dependencies: ["CLIKit"], resources: [.copy("Fixtures")]),
    ]
)
