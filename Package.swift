// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Glow",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .target(name: "GlowCore", path: "Sources/GlowCore"),
        .executableTarget(
            name: "Glow",
            dependencies: ["GlowCore"],
            path: "Sources/Glow"
        ),
        .testTarget(
            name: "GlowTests",
            dependencies: ["GlowCore"],
            path: "Tests/GlowTests"
        ),
    ]
)
