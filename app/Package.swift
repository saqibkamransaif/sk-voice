// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SKVoice",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "SKVoiceCore", targets: ["SKVoiceCore"]),
        .executable(name: "SKVoiceApp", targets: ["SKVoiceApp"]),
        .executable(name: "skvoice-check", targets: ["skvoice-check"]),
    ],
    targets: [
        .target(name: "SKVoiceCore"),
        .executableTarget(
            name: "SKVoiceApp",
            dependencies: ["SKVoiceCore"]
        ),
        .executableTarget(
            name: "skvoice-check",
            dependencies: ["SKVoiceCore"]
        ),
        .testTarget(
            name: "SKVoiceCoreTests",
            dependencies: ["SKVoiceCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
