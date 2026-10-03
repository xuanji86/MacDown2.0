// swift-tools-version: 6.2
import PackageDescription

// Pins are exact (PLAN 2.3), and chosen as a set (S4): Neon 0.6.0 does not compile against SwiftTreeSitter 0.9.0, and
// tree-sitter-markdown 0.5.x emits ABI 15 which the tree-sitter 0.23 runtime of released SwiftTreeSitter rejects.
let package = Package(
    name: "EditorKit",
    platforms: [.macOS(.v26)],
    products: [.library(name: "EditorKit", targets: ["EditorKit"])],
    dependencies: [
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", exact: "0.8.0"),
        .package(url: "https://github.com/ChimeHQ/Neon", exact: "0.6.0"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-markdown", exact: "0.4.1"),
    ],
    targets: [
        .target(
            name: "EditorKit",
            dependencies: [
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "Neon", package: "Neon"),
                .product(name: "TreeSitterMarkdown", package: "tree-sitter-markdown"),
            ],
            resources: [.copy("Resources")]
        ),
        .testTarget(name: "EditorKitTests", dependencies: ["EditorKit"]),
    ]
)
