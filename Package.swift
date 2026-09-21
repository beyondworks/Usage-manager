// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UsageManager",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "UsageCore"),
        .executableTarget(name: "UsageManager", dependencies: ["UsageCore"]),
    ],
    swiftLanguageModes: [.v5]
)
