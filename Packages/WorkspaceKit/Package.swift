// swift-tools-version: 6.2
import PackageDescription

// Data layer of the workspace sidebar (PLAN 4.11): file tree, FSEvents watcher, favorites/recents, tab session.
// Foundation + CoreServices only, no UI, so every piece is unit-testable. The few words it produces (sidebar headings and
// empty states, folder counts, search errors) live in its own String Catalog.
let package = Package(
    name: "WorkspaceKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [.library(name: "WorkspaceKit", targets: ["WorkspaceKit"])],
    targets: [
        .target(name: "WorkspaceKit", resources: [.process("Resources")]),
        .testTarget(name: "WorkspaceKitTests", dependencies: ["WorkspaceKit"]),
    ]
)
