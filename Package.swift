// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Lex",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic: sentence splitting, edit mapping, diffing, checking, the Claude client.
        .target(name: "LexCore"),
        // The menu-bar app: Accessibility, overlay, panels, hotkey.
        .executableTarget(name: "Lex", dependencies: ["LexCore"]),
        .testTarget(name: "LexCoreTests", dependencies: ["LexCore"]),
    ]
)
