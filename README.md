<div align="center">
  <img src="docs/logo.png" width="140" alt="SayIt logo">

  <h1>SayIt</h1>

  <p>
    <strong>Free, native macOS voice dictation with AI polish.</strong><br>
    Hold a key, speak, and clean, polished text lands at your cursor — in any app.
  </p>

  <p>
    <img alt="Platform" src="https://img.shields.io/badge/platform-macOS%2014%2B-blue">
    <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-Neural%20Engine-black">
    <img alt="Price" src="https://img.shields.io/badge/price-free-brightgreen">
    <img alt="License" src="https://img.shields.io/badge/license-MIT-blue">
  </p>

  <p>
    <strong><a href="https://github.com/Wentong-Liu/SayIt/releases/latest/download/SayIt.dmg">⬇️&nbsp;Download the latest SayIt.dmg</a></strong> · <a href="https://github.com/Wentong-Liu/SayIt/releases">All releases</a>
  </p>

  <p>
    <strong>English</strong> · <a href="README.zh-CN.md">简体中文</a>
  </p>
</div>

<div align="center">
  <img src="docs/demo.gif" width="720" alt="SayIt in action — hold the key, speak, and polished text appears at the cursor">
</div>

<hr>

SayIt turns your voice into polished text anywhere on your Mac. It's built for
people who already talk to AI all day — vibe coders, writers, anyone who would
rather speak than type. Hold the key, say what you mean, and the cleaned-up text
appears right where your cursor is.

## Why SayIt

### ⚡ Instant, on-device speech

Your speech is transcribed **locally on your Mac, accelerated by the Apple Neural
Engine** — the same NPU that powers on-device AI. It's quick, and it stays quick
no matter how long you spoke: measured on an **Apple M4 Pro** with the recommended
**large-v3-turbo** model, transcription runs in about **0.4 seconds** — an
~9-second clip became text in ~0.4 s, roughly **20× faster than real time**, and a
short phrase finishes just as fast. Exact speed depends on your Mac, but the work
always runs on-device, fully offline, and your audio never leaves your machine.

**On macOS 26 and later, SayIt defaults to Apple's built-in speech engine** — the new
on-device SpeechAnalyzer model, with **nothing to download**. It's faster still:
transcription is effectively instant, so quick that the "Transcribing…" indicator barely
has time to appear before your words land at the cursor. Older macOS — or your own
preference — falls back to the bundled WhisperKit model above.

### ♻️ Uses your Codex subscription to polish

If you vibe-code, you almost certainly already pay for **ChatGPT / Codex** or
**Claude**. SayIt polishes your dictation through that same account or API — cleaning up
filler words, punctuation, and phrasing — so there's **no second subscription and
nothing extra to pay**.

### 🆓 So it's actually free

Local transcription is free and offline. Polishing rides on the AI plan you
already have. You never pay SayIt anything — and polishing is optional, so you can
turn it off and SayIt stays 100% free and fully offline.

## How to use it

1. **Hold or tap** the trigger key (right ⌥ Option by default).
2. **Speak.**
3. **Release or tap again** — the polished text appears at your cursor.

That's it. Trigger key, interaction mode, which AI polishes your text, language,
and microphone are all in **Settings**.

## Settings

|  |  |
|:--:|:--:|
| <img src="docs/settings-speech.png" width="410" alt="Speech settings — recognition engine and local model"> | <img src="docs/settings-polish.png" width="410" alt="Polish settings — provider, style, and credentials"> |
| **Speech** — local model or cloud API, and which model | **Polish** — ChatGPT/Codex login or your own API key, plus style and model |

## Requirements

- macOS 14 or later, Apple Silicon recommended.
- **macOS 26+**: nothing to download — the speech model is built into the system.
- **macOS 14–15**: about 1–2 GB of free disk for the local WhisperKit model,
  downloaded automatically on first launch.

## Install

Download **[`SayIt.dmg`](https://github.com/Wentong-Liu/SayIt/releases/latest/download/SayIt.dmg)** from the [latest release](https://github.com/Wentong-Liu/SayIt/releases/latest), open it, and drag **SayIt** into **Applications**. It's Developer ID–signed and notarized, so it opens with no Gatekeeper warning.

On **macOS 26 and later**, SayIt is ready immediately: it uses Apple's built-in speech model, so there is **nothing to download** and dictation is near-instant from the very first try. On **macOS 14–15**, SayIt **automatically downloads the local WhisperKit model** (~1–2 GB, one time) on first launch — you can watch the progress in Settings and the menu bar — followed by a **one-time preparation** (the model is compiled for the Apple Neural Engine, a minute or two that first run); after that, dictation stays near-instant. Either way, grant **Microphone** and **Accessibility** in System Settings → Privacy & Security — Accessibility lets SayIt listen for the global hotkey and insert text into other apps (on macOS 26 you'll also be asked once for **Speech Recognition**).

To turn on AI polish, **sign in to your ChatGPT account manually in Settings → Polish** — this is the default and uses your existing ChatGPT/Codex subscription (you can also switch to your own OpenAI, Anthropic, or DeepSeek API key). Until you sign in, SayIt still works and inserts the raw transcription, just without polishing.

## Privacy

- **Local speech recognition is 100% on-device and offline** — your audio never
  leaves your Mac.
- **Cloud speech and AI polish run only if you turn them on**, using your own
  account or key.
- **Your clipboard is preserved** — SayIt restores whatever you had copied after
  inserting text.

## Contributing

Issues and pull requests are welcome. A couple of conventions: the Xcode project
is generated by XcodeGen from `project.yml` (add files under `App/` or
`SayItCore/Sources/` and re-run `xcodegen generate`), and docs, code comments, and
commit messages are in English.

## License

[MIT](LICENSE)

Built with [Claude Code](https://claude.com/claude-code).
