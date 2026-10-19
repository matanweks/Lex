// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Quill",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic: sentence splitting, edit mapping, diffing, checking, the Claude client.
        .target(name: "QuillCore"),
        // The menu-bar app: Accessibility, overlay, panels, hotkey.
        .executableTarget(name: "Quill", dependencies: ["QuillCore"]),
        .testTarget(name: "QuillCoreTests", dependencies: ["QuillCore"]),
    ]
)
