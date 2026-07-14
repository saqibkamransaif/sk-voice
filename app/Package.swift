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
    dependencies: [
        // Native multilingual ASR (Urdu) for translation mode — Metal-accelerated.
        // Pinned: 1.7.4 is the last tag shipping Package.swift (SPM support was
        // dropped upstream in 1.7.5+) and it supports large-v3-turbo models.
        .package(url: "https://github.com/ggml-org/whisper.cpp.git", exact: "1.7.4"),
    ],
    targets: [
        .target(
            name: "SKVoiceCore",
            dependencies: [
                .product(name: "whisper", package: "whisper.cpp"),
            ]
        ),
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
