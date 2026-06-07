// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SayItCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SayItCore", targets: ["SayItCore"]),
    ],
    dependencies: [
        // 本地 STT 引擎：WhisperKit（基于 Core ML 的 Whisper 实现）。
        // 模型在运行期首次从 HuggingFace 拉取，构建/测试阶段不下载。
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "SayItCore",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
            ]
        ),
        .testTarget(name: "SayItCoreTests", dependencies: ["SayItCore"]),
    ]
)
