// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ShotPad",
    platforms: [.macOS("15.0")],
    targets: [
        .target(name: "ShotPadCore", path: "Sources/ShotPadCore"),
        .executableTarget(name: "ShotPad", dependencies: ["ShotPadCore"], path: "Sources/ShotPad"),
        .testTarget(name: "ShotPadCoreTests", dependencies: ["ShotPadCore"], path: "Tests/ShotPadCoreTests"),
        .testTarget(name: "ShotPadInteractionTests", dependencies: ["ShotPad"], path: "Tests/ShotPadInteractionTests"),
    ],
    swiftLanguageModes: [.v5]
)
