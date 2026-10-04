// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ExtensionAPI",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [.library(name: "ExtensionAPI", targets: ["ExtensionAPI"])],
    // WorkspaceKit: the search value types (SearchQuery / SearchHit) and the built-in backend live next to the folder walk they reuse.
    dependencies: [.package(path: "../MarkdownCore"), .package(path: "../WorkspaceKit")],
    targets: [
        .target(name: "ExtensionAPI", dependencies: ["MarkdownCore", "WorkspaceKit"], resources: [.process("Resources")]),
        .testTarget(name: "ExtensionAPITests", dependencies: ["ExtensionAPI"]),
    ]
)
