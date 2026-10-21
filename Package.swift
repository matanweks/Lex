// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Lex",
    // iOS is for the iPhone app in iOS/, which uses LexCore. The app itself sets iOS 26.
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "Lex", targets: ["Lex"]),
        .library(name: "LexCore", targets: ["LexCore"]),
    ],
    targets: [
        // Pure logic: sentence splitting, edit mapping, diffing, checking, the Claude client.
        .target(name: "LexCore"),
        // The menu-bar app: Accessibility, overlay, panels, hotkey.
        .executableTarget(name: "Lex", dependencies: ["LexCore"]),
        .testTarget(name: "LexCoreTests", dependencies: ["LexCore"]),
    ]
)
