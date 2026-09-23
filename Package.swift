// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VibeWake",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "VibeWake",
            path: "Sources/VibeWake",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("AppKit")]
        )
    ]
)
