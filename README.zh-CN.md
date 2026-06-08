<div align="center">
  <img src="docs/logo.png" width="140" alt="SayIt logo">

  <h1>SayIt</h1>

  <p>
    <strong>免费、原生的 macOS 语音输入。</strong><br>
    按一个键、说话，润色干净的文字直接落到光标处——在任何 app 里。
  </p>

  <p>
    <img alt="Platform" src="https://img.shields.io/badge/platform-macOS%2014%2B-blue">
    <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-Neural%20Engine-black">
    <img alt="Price" src="https://img.shields.io/badge/price-free-brightgreen">
    <img alt="License" src="https://img.shields.io/badge/license-see%20LICENSE-lightgrey">
  </p>

  <p>
    <a href="README.md">English</a> · <strong>简体中文</strong>
  </p>
</div>

<hr>

**喜欢 Typeless，但觉得免费额度不够用？** SayIt 用**本地模型**做语音识别、用**你已经在付的 Codex（或 Claude）订阅**来润色——**完全免费**，没有额度、没有月费。

按住键说话，松开，润色好的文字就出现在你光标的位置。给整天对着 AI 说话的人用——vibe coder、写东西的人、任何「宁可说也不想打字」的人。

## 为什么选 SayIt

### ⚡ 本地识别，快到几乎即时

语音在**你的 Mac 本地转写，走苹果神经引擎（NPU）**——就是驱动端侧 AI 的那块芯片。快，而且不管你说多久都快：在 **Apple M4 Pro** 上用推荐的 **large-v3-turbo** 模型实测，转写约 **0.4 秒**——9 秒的音频不到半秒出字，约 **20× 实时**，短句也一样快。速度因机器而异，但识别全程**在本地、离线、音频不出本机**。

### ♻️ 用你已有的 Codex 订阅来润色

你要是在 vibe coding，多半已经在付 **ChatGPT / Codex** 或 **Claude**。SayIt 直接用那个账号润色你的口述稿——去语气词、补标点、顺措辞——所以**不用再订第二个、不用额外花钱**。

### 🆓 所以是真·免费

本地识别免费且离线；润色蹭你已有的 AI 订阅。你**永远不用给 SayIt 付钱**。而且润色是可选的——关掉它，SayIt 照样 100% 免费、纯离线。

## 怎么用

1. **按住或轻点**触发键（默认右 ⌥ Option）。
2. **说话。**
3. **松开或再点一下**——润色好的文字出现在光标处。

就这样。触发键、交互方式、用哪个 AI 润色、界面语言、麦克风，都在**设置**里。

## 环境要求

- macOS 14 及以上，推荐 Apple Silicon。
- 本地模型约需 1–2 GB 磁盘，首次使用时下载一次。

## 安装

目前请从源码构建（见下）。首次启动时，在 系统设置 → 隐私与安全性 里授予**麦克风**和**辅助功能**——辅助功能用于监听全局热键、并把文字注入到其它 app。

## 隐私

- **本地识别 100% 在本机、离线**——用本地引擎时，音频绝不离开你的 Mac。
- **云端识别和 AI 润色只在你主动开启时才用**，用的是你自己的账号或 key。
- **剪贴板会还原**——SayIt 注入文字后，会把你原本复制的内容放回去。

## 从源码构建

SayIt 用 [XcodeGen](https://github.com/yonaskolb/XcodeGen)；`project.yml` 是唯一真相源，生成的 `SayIt.xcodeproj` 不入库。

```sh
brew install xcodegen
cp Local.xcconfig.example Local.xcconfig   # 把 DEVELOPMENT_TEAM 设成你的 Apple Developer Team ID（只构建核心包可不填）
xcodegen generate
scripts/build-and-install.sh               # 构建 Release 版 SayIt.app 并安装到 /Applications
```

可移植的核心逻辑在 **SayItCore** Swift 包里：

```sh
swift build --package-path SayItCore
swift test  --package-path SayItCore
```

## 贡献

欢迎提 issue 和 PR。几条约定：Xcode 工程由 XcodeGen 从 `project.yml` 生成（新文件放 `App/` 或 `SayItCore/Sources/` 下，再跑 `xcodegen generate`）；文档、代码注释、提交信息一律用英文。

## 许可

开源——见 LICENSE 文件。
