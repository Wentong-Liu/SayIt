// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SayItCore",
    // Declare the default localization so `Bundle.module` can load Resources/Localizable.xcstrings (en + zh-Hans).
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SayItCore", targets: ["SayItCore"]),
    ],
    dependencies: [
        // Local STT engine: WhisperKit (a Core ML-based Whisper implementation).
        // The model is fetched from HuggingFace on first run at runtime; it is not downloaded during build/test.
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "SayItCore",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            // String catalog for in-package user-facing text such as the HUD (generates Bundle.module's .lproj).
            // The dictation start/stop chime cues are .copy (not .process): CAFs are opaque binaries that must be
            // bundled byte-verbatim, whereas .process is for assets Xcode compiles (the .xcstrings catalog).
            resources: [
                .process("Resources/Localizable.xcstrings"),
                .copy("Resources/start.caf"),
                .copy("Resources/stop.caf"),
            ]
        ),
        .testTarget(name: "SayItCoreTests", dependencies: ["SayItCore"]),
    ]
)
