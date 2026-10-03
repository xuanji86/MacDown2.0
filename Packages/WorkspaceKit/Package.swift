// swift-tools-version: 6.2
import PackageDescription

// Data layer of the workspace sidebar (PLAN 4.11): file tree, FSEvents watcher, favorites/recents, tab session.
// Foundation + CoreServices only, no UI, so every piece is unit-testable.
let package = Package(
    name: "WorkspaceKit",
    platforms: [.macOS(.v26)],
    products: [.library(name: "WorkspaceKit", targets: ["WorkspaceKit"])],
    targets: [
        .target(name: "WorkspaceKit"),
        .testTarget(name: "WorkspaceKitTests", dependencies: ["WorkspaceKit"]),
    ]
)
