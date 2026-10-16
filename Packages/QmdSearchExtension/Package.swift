// swift-tools-version: 6.2
import PackageDescription

// Only the App target links this (PLAN 4.17; Scripts/check-module-boundaries.sh keeps core code, Quick Look and the CLI
// from importing it). WorkspaceKit is where the `SearchProvider` contract's value types (SearchQuery, SearchHit) and the
// FolderWatcher live; ExtensionAPI already depends on it, so this adds no edge to the graph.
let package = Package(
    name: "QmdSearchExtension",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [.library(name: "QmdSearchExtension", targets: ["QmdSearchExtension"])],
    dependencies: [
        .package(path: "../ExtensionAPI"),
        .package(path: "../WorkspaceKit"),
    ],
    targets: [
        .target(name: "QmdSearchExtension", dependencies: ["ExtensionAPI", "WorkspaceKit"], resources: [.process("Resources")]),
        .testTarget(name: "QmdSearchExtensionTests", dependencies: ["QmdSearchExtension", "ExtensionAPI", "WorkspaceKit"], resources: [.copy("Fixtures")]),
    ]
)
