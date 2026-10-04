// swift-tools-version: 6.2
import PackageDescription

// The paper side of export: lays an exported HTML page out in an offscreen WKWebView and paginates it through AppKit's print
// system (File > Export > PDF, Print, and `macdown2 render --export pdf`). AppKit + WebKit, so it is a package of its own:
// CLIKit stays Foundation-only, and only the app and the `macdown2` tool target link this.
let package = Package(
    name: "PrintKit",
    platforms: [.macOS(.v26)],
    products: [.library(name: "PrintKit", targets: ["PrintKit"])],
    dependencies: [.package(path: "../MarkdownCore"), .package(path: "../WebAssets")],
    targets: [
        .target(name: "PrintKit", dependencies: ["MarkdownCore", "WebAssets"]),
        .testTarget(name: "PrintKitTests", dependencies: ["PrintKit", "MarkdownCore"]),
    ]
)
