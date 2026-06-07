# SayIt

A macOS menu-bar voice dictation app. Hold a hotkey and speak, let an LLM
polish the transcript, then inject the result at the cursor in whatever app
you are using.

## Architecture

- **Swift 6**, minimum **macOS 14.0**. UI built with SwiftUI + AppKit.
- Menu-bar accessory app (no Dock icon, `LSUIElement=1`).
- **SayItCore/**: a local SwiftPM package holding most of the portable logic
  (OAuth / LLM providers / Keychain, etc.).
- **App/**: a thin app-target shell (`@main`, the AppDelegate accessory
  policy, SettingsView, Info.plist, entitlements).
- **project.yml**: the XcodeGen configuration and the single source of truth
  for the Xcode project. The generated `*.xcodeproj` is not committed; sources
  are included by directory glob, so adding a file needs no project edit.

## Fixed technical decisions

- Bundle id / Keychain service: `com.liuwentong.SayIt`.
- Entitlements: Hardened Runtime on, App Sandbox off (needs global
  Accessibility, CGEvent, and microphone access).
- Info.plist declares `NSMicrophoneUsageDescription`.

## Building

Prerequisite: install [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

### Code-signing setup (one-time)

The code-signing Team ID is not committed. Configure your own before
generating the Xcode project:

```sh
cp Local.xcconfig.example Local.xcconfig
# Edit Local.xcconfig and set DEVELOPMENT_TEAM to your Apple Developer Team ID
# (Xcode > Settings > Accounts, or developer.apple.com > Membership).
```

`Local.xcconfig` is gitignored and wired into the Debug/Release build
configurations through `configFiles` in `project.yml`. Leaving
`DEVELOPMENT_TEAM` empty is fine for `swift build` and running the package
tests without code signing.

### 1) Build the Core package

```sh
swift build --package-path SayItCore
swift test  --package-path SayItCore
```

### 2) Generate the project and build the app

```sh
# Generate SayIt.xcodeproj from project.yml (re-run after editing project.yml)
xcodegen generate

xcodebuild \
  -project SayIt.xcodeproj \
  -scheme SayIt \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/sayit-dd \
  build
```

> `SayIt.xcodeproj` is a generated artifact and is gitignored. Put new source
> files under `App/` or `SayItCore/Sources/` and re-run `xcodegen generate` —
> no manual project edits required.
