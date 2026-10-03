// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MarkdownCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "MarkdownCore", targets: ["MarkdownCore"])],
    dependencies: [.package(path: "../WebAssets")],
    targets: [
        .target(name: "MarkdownCore", dependencies: ["WebAssets"]),
        .testTarget(name: "MarkdownCoreTests", dependencies: ["MarkdownCore"], resources: [.copy("Fixtures")]),
    ]
)
