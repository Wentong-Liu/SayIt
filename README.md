<div align="center">
  <img src="docs/logo.png" width="140" alt="SayIt logo">

  <h1>SayIt</h1>

  <p>
    <strong>A completely free, open-source macOS voice-dictation app</strong><br>
    Hold or tap a hotkey, speak, and clean polished text lands at your cursor in any app.
  </p>

  <p>
    <img alt="Platform" src="https://img.shields.io/badge/platform-macOS%2014%2B-blue">
    <img alt="Language" src="https://img.shields.io/badge/Swift-6-orange">
    <img alt="License" src="https://img.shields.io/badge/license-see%20LICENSE-lightgrey">
    <img alt="Free" src="https://img.shields.io/badge/price-free-brightgreen">
  </p>
</div>

<hr>

## Why SayIt

SayIt is a free and open-source alternative to paid dictation tools like
[Typeless](https://typeless.app) and [Wispr Flow](https://wisprflow.ai) — and it
matches that quality at **zero cost**.

It is free because of two choices:

- **Speech-to-text runs locally**, on-device, with a Whisper model
  ([WhisperKit](https://github.com/argmaxinc/WhisperKit)). No API bill, fully
  offline, fully private.
- **AI polishing runs through your ChatGPT login** (Codex / Responses API),
  i.e. a subscription you may already pay for — so there is no extra
  per-token API spend for the core dictation loop.

Hold *or* tap the trigger key, speak, then release or tap again. SayIt transcribes
your speech, lets an LLM clean it up, and inserts the polished text at the
cursor in **any** macOS app.

## Features

- **Global hotkey, two interaction modes** — single-tap toggle (the default:
  tap to start, tap again to stop, Typeless-style) *and* hold-to-talk
  (push-to-talk). Default trigger key is the right ⌘.
- **Local STT** — WhisperKit running on-device, fully offline and private (default).
- **Cloud STT** — optional OpenAI-compatible transcription API using your own
  key and configurable base URL.
- **AI polish via ChatGPT login** — the Codex Responses API uses your existing
  ChatGPT subscription, with no per-token API spend.
- **Bring-your-own-key polish** — OpenAI, DeepSeek, or Anthropic with your own
  API key, as an alternative to ChatGPT login.
- **Polish styles** — smart (default), punctuation-only, formal, or casual.
- **Menu-bar app** — runs as a menu-bar accessory with no Dock icon.
- **Live recording HUD** — a mic-reactive waveform while you speak, plus a
  progress bar that tracks transcription and polishing.
- **Automatic CN/EN language detection** — no manual language switching.
- **Fully localized UI** — English and 简体中文 (follows your system language by
  default).

## How it works

```
hotkey → record → STT (local or cloud) → LLM polish → inject at cursor (pasteboard + ⌘V)
```

## Why it's free

- **Local model = free, offline transcription.** The Whisper model is
  downloaded once and then runs entirely on your Mac — no network, no API bill.
- **ChatGPT / Codex login = polish through a subscription you may already pay
  for.** Polishing goes through the ChatGPT login (Codex Responses API), so the
  core dictation loop costs you nothing extra.
- **Everything else is optional.** Cloud STT and the other API-key providers
  (OpenAI / DeepSeek / Anthropic) are available only if you choose to bring your
  own key.

**AI polishing is optional — SayIt is completely free without it.** Speech-to-text
runs entirely on a local, on-device model, so the app is fully usable with no
account, no network, and no cost. Polishing (cleaning up filler words,
punctuation, and phrasing) is opt-in: leave it off and SayIt stays 100% free;
turn it on and power it with a ChatGPT / Codex subscription you may already have
— no per-token API bill — or with your own API key. Either way, you never pay
SayIt anything.

## Why Mac-only (built natively in Swift)

SayIt's cost story and its platform story are the same story:

- **Free follows from local.** Because transcription runs on a local,
  on-device model, there is no server to pay for and no per-use cost — that is
  the core reason SayIt can be completely free.
- **Local is practical because of Apple Silicon.** Running a full-size speech
  model on-device fast enough for live dictation needs real machine-learning
  hardware. Apple Silicon Macs ship with the **Apple Neural Engine (ANE)**, and
  SayIt reaches it through **Core ML**: WhisperKit runs OpenAI's Whisper
  `large-v3-turbo` on the Neural Engine, and the turbo variant's small decoder
  keeps it quick.
- **Native Swift is what unlocks that.** SayIt is a native Swift + SwiftUI app,
  not a cross-platform or Electron wrapper. Being native is exactly what lets it
  tap Core ML and the Neural Engine directly — an edge cross-platform tools
  can't match, and the reason SayIt is Mac-only (macOS 14+) by design, as well
  as fast, efficient, and free.

## Requirements

- macOS 14 or later.
- Apple Silicon recommended (for fast on-device transcription).
- ~1–2 GB of free disk for the local model. The default model
  (`large-v3-turbo`) is downloaded on first use and cached at
  `~/Library/Application Support/SayIt/models`.

## Build from source

SayIt uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `project.yml` is
the single source of truth for the Xcode project, and the generated
`SayIt.xcodeproj` is not committed.

1. **Install XcodeGen:**

   ```sh
   brew install xcodegen
   ```

2. **Configure code signing.** The Team ID is not committed; copy the example
   and set your own:

   ```sh
   cp Local.xcconfig.example Local.xcconfig
   # Edit Local.xcconfig and set DEVELOPMENT_TEAM to your Apple Developer Team ID
   # (Xcode > Settings > Accounts, or developer.apple.com > Membership).
   ```

   `Local.xcconfig` is gitignored and wired into the Debug/Release builds via
   `configFiles` in `project.yml`. Leaving `DEVELOPMENT_TEAM` empty is fine for
   building and testing the Core package without code signing.

3. **Generate the project:**

   ```sh
   xcodegen generate
   ```

4. **Build the app** — open `SayIt.xcodeproj` and build the `SayIt` scheme in
   Xcode, or from the command line:

   ```sh
   xcodebuild \
     -project SayIt.xcodeproj \
     -scheme SayIt \
     -destination 'platform=macOS,arch=arm64' \
     -derivedDataPath build \
     build
   ```

   Or run `scripts/build-and-install.sh` to build a Release `SayIt.app` and
   install it to `/Applications`.

The portable logic lives in the **SayItCore** SwiftPM package and can be built
and tested directly:

```sh
swift build --package-path SayItCore
swift test  --package-path SayItCore
```

On first launch, grant **Microphone** and **Accessibility** permissions in
System Settings > Privacy & Security (Accessibility is needed for the global
hotkey and for inserting text into other apps).

## Usage

- **Default (single-tap):** tap the trigger key (right ⌘) to start recording,
  then tap it again to stop.
- **Hold-to-talk:** switch the interaction mode in Settings, then hold the
  trigger key to talk and release to finish.

After you stop, SayIt transcribes the audio, polishes it with the configured
LLM, and inserts the result at your cursor.

Everything is configurable in **Settings**: STT engine and model, polish
provider (ChatGPT login or API key) and style, trigger key, interaction mode,
UI language, and microphone input device.

## Privacy

- **Local STT is fully on-device and offline** — your audio never leaves your
  Mac when using the default local engine.
- **Cloud STT and LLM polish run only if you opt in** with your own credentials
  (your ChatGPT login or your own API key).
- **Your clipboard is preserved** — SayIt snapshots the pasteboard before
  inserting text via ⌘V and restores it afterward.

## Contributing

Contributions are welcome — please open an issue or a pull request.

A few project conventions:

- The Xcode project is generated by XcodeGen from `project.yml`. Add new source
  files under `App/` or `SayItCore/Sources/` and re-run `xcodegen generate` —
  no manual `.xcodeproj` edits required (it is a gitignored artifact).
- Run `swift test --package-path SayItCore` for the Core package, and build the
  `SayIt` scheme for the app.
- Docs, code comments, and commit messages are in English.

## License

Open source — see the LICENSE file.
