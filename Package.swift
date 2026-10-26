// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Lyra",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.7"),
    ],
    targets: [
        .target(name: "LyraCore"),
        .target(name: "LyraAudio", dependencies: ["LyraCore"]),
        .target(name: "LyraSpeech", dependencies: [
            "LyraCore",
            .product(name: "FluidAudio", package: "FluidAudio"),
        ]),
        .executableTarget(name: "Lyra", dependencies: ["LyraCore", "LyraAudio", "LyraSpeech"]),
        .testTarget(name: "LyraCoreTests", dependencies: ["LyraCore"]),
        .testTarget(
            name: "LyraIntegrationTests",
            dependencies: ["LyraAudio", "LyraSpeech"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
