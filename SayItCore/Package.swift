// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SayItCore",
    // 声明默认本地化：让 `Bundle.module` 能加载 Resources/Localizable.xcstrings（en + zh-Hans）。
    defaultLocalization: "en",
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
            ],
            // HUD 等包内 user-facing 文案的字符串目录（生成 Bundle.module 的 .lproj）。
            resources: [
                .process("Resources/Localizable.xcstrings"),
            ]
        ),
        .testTarget(name: "SayItCoreTests", dependencies: ["SayItCore"]),
    ]
)
