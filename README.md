# SayIt

macOS 菜单栏语音听写 app（对标 Typeless）。按住热键说话 → AI 润色 → 注入当前 App 光标处。

## 架构

- **Swift 6**，最低 **macOS 14.0**。UI 用 SwiftUI + AppKit。
- 菜单栏 accessory app（无 Dock 图标，`LSUIElement=1`）。
- **SayItCore/**：本地 SwiftPM 包，承载绝大多数可移植逻辑（OAuth / Provider / Keychain 等）。
- **App/**：App target 薄壳（`@main`、AppDelegate accessory 策略、SettingsView、Info.plist、entitlements）。
- **project.yml**：XcodeGen 配置，是工程的唯一真相源。生成的 `*.xcodeproj` 不入库；源码以目录 glob 纳入（加文件无需改工程）。

## 固定技术决策

- bundle id / Keychain service：`com.liuwentong.SayIt`。
- entitlements：Hardened Runtime 开启，App Sandbox 关闭（后续需要全局 AX、CGEvent、麦克风）。
- Info.plist 含 `NSMicrophoneUsageDescription`。

## 构建

前置：安装 [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）。

### 1) 构建 Core 包

```sh
swift build --package-path SayItCore
swift test  --package-path SayItCore
```

### 2) 生成工程并构建 App

```sh
# 由 project.yml 生成 SayIt.xcodeproj（每次改 project.yml 后重跑）
xcodegen generate

xcodebuild \
  -project SayIt.xcodeproj \
  -scheme SayIt \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/sayit-dd \
  build
```

> `SayIt.xcodeproj` 是生成产物，已在 `.gitignore` 中。新增源码文件放入 `App/` 或 `SayItCore/Sources/`，无需手改工程文件，重新 `xcodegen generate` 即可。
