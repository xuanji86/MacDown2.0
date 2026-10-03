// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ExtensionAPI",
    platforms: [.macOS(.v26)],
    products: [.library(name: "ExtensionAPI", targets: ["ExtensionAPI"])],
    dependencies: [.package(path: "../MarkdownCore")],
    targets: [
        .target(name: "ExtensionAPI", dependencies: ["MarkdownCore"]),
        .testTarget(name: "ExtensionAPITests", dependencies: ["ExtensionAPI"]),
    ]
)
