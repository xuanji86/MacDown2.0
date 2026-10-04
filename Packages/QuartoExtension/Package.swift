// swift-tools-version: 6.2
import PackageDescription

// Only the App target links this (PLAN 4.17; Scripts/check-module-boundaries.sh keeps core code, Quick Look and the CLI
// from importing it). It needs the protocols and the renderer types, never EditorKit or the app.
let package = Package(
    name: "QuartoExtension",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [.library(name: "QuartoExtension", targets: ["QuartoExtension"])],
    dependencies: [
        .package(path: "../ExtensionAPI"),
        .package(path: "../MarkdownCore"),
        .package(path: "../WebAssets"),
    ],
    targets: [
        .target(name: "QuartoExtension", dependencies: ["ExtensionAPI", "MarkdownCore"], resources: [.process("Resources")]),
        .testTarget(name: "QuartoExtensionTests", dependencies: ["QuartoExtension", "ExtensionAPI", "MarkdownCore", "WebAssets"]),
    ]
)
