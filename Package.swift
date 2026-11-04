// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Mac2Hog",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Mac2Hog", targets: ["Mac2Hog"]),
        .library(name: "Mac2HogCore", targets: ["Mac2HogCore"]),
    ],
    targets: [
        // Platform-independent engine: audio analysis, timecode, OSC, Hog 4 mapping, show runner.
        .target(name: "Mac2HogCore"),
        // SwiftUI macOS application.
        .executableTarget(
            name: "Mac2Hog",
            dependencies: ["Mac2HogCore"],
            // Dock icon when running unbundled (`swift run`); the .app uses Resources/AppIcon.
            resources: [.copy("Resources/AppIcon.png")]
        ),
        .testTarget(name: "Mac2HogCoreTests", dependencies: ["Mac2HogCore"]),
    ]
)
