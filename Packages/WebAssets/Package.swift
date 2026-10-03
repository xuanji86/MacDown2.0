// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WebAssets",
    platforms: [.macOS(.v26)],
    products: [.library(name: "WebAssets", targets: ["WebAssets"])],
    targets: [
        .target(name: "WebAssets", resources: [.copy("Resources")]),
        .testTarget(name: "WebAssetsTests", dependencies: ["WebAssets"]),
    ]
)
