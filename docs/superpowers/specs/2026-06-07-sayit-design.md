# SayIt 设计 Spec

- 文档版本：v1（2026-06-07）
- 作者：SayIt 项目
- 状态：地基阶段设计确认稿（已确认的固定技术决策见下文，不在本文重复推翻）
- 仓库：`/Users/liuwentong/Project/me/sayit`（git main，零提交）
- 可复用项目：`/Users/liuwentong/Project/me/ZhiYu`（原生 Swift6/macOS14 菜单栏 app）

---

## 1. 产品定义与目标

SayIt 是一个 macOS 菜单栏（accessory）语音听写 app，对标 [Typeless](https://typeless.app)。核心交互一句话描述：

> 按住热键说话 → 实时录音 HUD → 松手 → 本地/云端 STT 转写 → LLM 润色（去口水词、补标点、整理结构）→ 把成稿注入到松手前正在编辑的那个 App 的光标处。

### 1.1 价值主张
- **全局可用**：不绑定某个特定 App。任何能接受键盘输入的文本框（备忘录、浏览器输入框、IDE、聊天框、邮件）都能用语音口述。
- **AI 润色而非裸转写**：把"嗯…那个…我想说的是"这种口语流，整理成可直接发出的书面/口语成稿。这是和系统自带听写的关键差异。
- **便宜/免费**：默认走本地 WhisperKit（不出设备、零调用成本），润色可选本地不可用时才走云端；云端润色支持 ChatGPT 订阅 OAuth 登录（复用已有订阅额度）或自带 API key。
- **快**：按住即录、松手即出，目标端到端可感延迟尽量短（先转写后润色，润色可被用户关闭跳过）。

### 1.2 目标用户
- 中英混合输入者（中文为主、夹英文术语/产品名），M4 Pro 48GB 这类有本地算力的 Mac 用户。
- 想要"说得比打得快"、且不愿把语音上传到云的隐私敏感用户（本地模式）。

### 1.3 非目标（v1 明确不做）
- 不做实时边说边出字（streaming partials），v1 是"松手后整段处理"。
- 不做命令/语音控制（"打开 Safari"之类），只做听写 + 润色注入。
- 不做多语言全覆盖，聚焦中英混合。
- 不做云盘/历史同步/账号体系（除 ChatGPT OAuth 仅用于调模型）。

---

## 2. 需求与约束

### 2.1 平台与硬件
- 仅 macOS，最低 macOS 14.0；Swift 6。
- 目标机型基线：Apple Silicon（M4 Pro / 48GB 内存），本地 large-v3-turbo 模型可流畅跑。

### 2.2 语言
- 中英混合（code-switching）为一等公民：转写与润色都不得擅自把英文翻成中文或反向，保留原说话语言。

### 2.3 STT（双路统一接口）
- 本地路：WhisperKit（默认 large-v3-turbo）。
- 云端路：OpenAI 兼容转写接口（如 `gpt-4o-mini-transcribe` / `whisper-1` 类）。
- 两路统一在一个 `Transcriber` 协议后面，调用方（DictationCoordinator）不感知具体实现。

### 2.4 润色（LLM Provider）
- 润色走 LLM Provider 抽象（复用 ZhiYu 的 `LLMProvider`）。
- 凭据两种：
  1. ChatGPT 订阅 OAuth 登录（复用 ZhiYu 的 ChatGPTOAuth / CodexResponsesProvider / CodexLoginService，走订阅额度，无 API key）。
  2. 自带 API key（OpenAI 兼容 / Anthropic 等，存 Keychain）。

### 2.5 交付形态
- 做成可分发产品，同时开源。Developer ID + 公证 + Hardened Runtime；App Sandbox 关闭（需全局 AX / CGEvent / 麦克风）。

### 2.6 交互
- 同时支持两种触发：**按住说话（push-to-talk）** 与 **双击热键切换（toggle）**。**默认按住**。
- 单热键，双击与按住共用同一物理键（修饰键）：双击进入持续录音、再按一下停止；纯按住则松手停止。

### 2.7 v1 范围
- v1 只做核心闭环：按住录音 → STT → 润色 →注入。其余打磨/扩展进 v2/v3（见第 10 节）。

### 2.8 固定技术决策（不得自行更改）
- UI：SwiftUI + AppKit。菜单栏 accessory（LSUIElement=1，无 Dock 图标）。
- 构建：XcodeGen，`project.yml` 为唯一真相源；生成的 `*.xcodeproj` 进 `.gitignore`。源码用目录 glob 纳入（加文件不改工程文件）。
- 包结构：`SayItCore`（本地 SwiftPM 包，`platforms: [.macOS(.v14)]`，可 import AppKit）+ `App/`（薄壳）+ 根 `project.yml`。
- 产品名/scheme：`SayIt`。bundle id 与 Keychain service：`com.liuwentong.SayIt`。
- entitlements：Hardened Runtime 开，App Sandbox 关。Info.plist 含 `NSMicrophoneUsageDescription`。
- 地基阶段**不引入** WhisperKit 或任何 STT/录音依赖；地基只做脚手架 + 移植 OAuth/Provider/Keychain。

---

## 3. 整体架构

```
sayit/
├── project.yml                  # XcodeGen 唯一真相源（生成的 .xcodeproj 不提交）
├── SayItCore/                   # 本地 SwiftPM 包：绝大多数可移植逻辑
│   └── Sources/SayItCore/
│       ├── Provider/            # 复用 ZhiYu：LLMProvider / OpenAICompatible / Anthropic / ProviderConfig ...
│       ├── OAuth/               # 复用 ZhiYu：ChatGPTOAuth / PKCE / OAuthTokens / CodexResponsesProvider
│       ├── Transcribe/          # 新：Transcriber 协议 + FakeTranscriber + CloudTranscriber
│       ├── Polish/              # 新：PolishPromptBuilder + PolishPipeline + PolishStyle
│       ├── Input/               # 复用 ZhiYu：DoubleTapDetector（纯逻辑）
│       └── Util/                # HTTP 常量、错误类型等
└── App/                         # App target 薄壳（@main / AppDelegate / 设置界面 / 平台依赖逻辑）
    ├── SayItApp.swift           # @main
    ├── AppDelegate.swift        # accessory 策略 + 单实例 + 启动监听
    ├── Config/AppConfig.swift   # UserDefaults 配置（复用 ZhiYu 思路，去掉微信特有项）
    ├── Secrets/KeychainStore.swift   # 复用 ZhiYu（service 改 com.liuwentong.SayIt）
    ├── OAuth/CodexLoginService.swift # 复用 ZhiYu（回环 OAuth）
    ├── LLM/ProviderFactory.swift     # 复用 ZhiYu（数据驱动构造 Provider）
    ├── Permissions/AccessibilityAuthorizer.swift # 复用 ZhiYu
    ├── Audio/AudioRecorder.swift     # 新：AVAudioEngine 录音 → PCM/WAV
    ├── STT/WhisperKitTranscriber.swift # 新：本地 WhisperKit（地基阶段不引入）
    ├── Inject/TextInjector.swift     # 新：AX 优先 + CGEvent/剪贴板兜底注入
    ├── Hotkey/HotkeyManager.swift    # 新：按住 + 双击统一手势（复用 DoubleTapDetector）
    ├── Panel/RecordingPanel.swift    # 新：录音 HUD NSPanel（复用 ZhiYu NSPanel 模式）
    ├── Settings/SettingsView.swift   # 新：SwiftUI 设置
    └── Dictation/DictationCoordinator.swift # 新：端到端编排
```

### 3.1 分层原则
- **SayItCore**：纯可移植逻辑 + 网络 Provider + 提示词/管线/转写协议。可单元测试、不依赖 App 生命周期。WhisperKit 因为是 App 层依赖（模型下载、CoreML），其 `Transcriber` 实现放 App 层（协议在 Core，实现在 App）。
- **App 薄壳**：`@main`、AppDelegate、所有需要 AppKit 运行环境/系统权限的胶水（录音、注入、热键、HUD、OAuth 回环、Keychain），以及 SwiftUI 设置界面。

### 3.2 模块职责
| 模块 | 层 | 职责 |
|---|---|---|
| `AudioRecorder` | App | 麦克风采集，输出 16kHz 单声道 PCM（喂 WhisperKit）/ WAV（喂云端）。 |
| `Transcriber`（协议）| Core | `func transcribe(audio:) async throws -> String`，本地/云端统一。 |
| `WhisperKitTranscriber` | App | 本地实现，模型 large-v3-turbo。 |
| `CloudTranscriber` | Core | OpenAI 兼容转写实现。 |
| `PolishPromptBuilder` | Core | 根据风格 + 当前 App 名 + 原文，构造润色提示词。 |
| `PolishPipeline` | Core | 调 LLMProvider 做润色；可跳过；失败回退原文。 |
| `TextInjector` | App | 把成稿注入聚焦 App 光标处（AX → CGEvent → 剪贴板 三级）。 |
| `HotkeyManager` | App | 全局监听热键，区分按住/双击，回调 start/stop。 |
| `RecordingPanel` | App | 录音中浮窗 HUD（电平 + 状态文案）。 |
| `SettingsView` | App | Provider/模型/STT 路/风格/热键/权限设置。 |
| `DictationCoordinator` | App | 串起整个流程的状态机。 |
| `OAuth + Provider + Keychain` | Core/App | 直接复用 ZhiYu。 |

---

## 4. 复用 ZhiYu 清单

ZhiYu 与 SayIt 共享"菜单栏 accessory + 全局热键 + 浮动 NSPanel + AX/CGEvent + LLM Provider + OAuth + Keychain"这一整套基础设施。下面逐项标注**直接复用**还是**需通用化改造**。

| ZhiYu 来源 | 复用方式 | 备注 / 改造点 |
|---|---|---|
| `ZhiYuCore/Provider/LLMProvider.swift` | **直接复用** | 协议 `complete(messages:) async throws -> String`，重命名为 SayItCore 即可。 |
| `ZhiYuCore/Provider/OpenAICompatibleProvider.swift` | **直接复用** | 润色走 chat/completions。 |
| `ZhiYuCore/Provider/AnthropicProvider.swift` | **直接复用** | 润色备选。 |
| `ZhiYuCore/Provider/ProviderConfig.swift` | **直接复用** | name/baseURL/model 工厂。 |
| `ZhiYuCore/Provider/{HTTPConstants,HTTPResponseValidator,ProviderError,LLMMessage,LLMDefaults}` | **直接复用** | 网络底座。 |
| `ZhiYuCore/OAuth/{ChatGPTOAuth,PKCE,OAuthTokens}.swift` | **直接复用** | ChatGPT 订阅登录协议。 |
| `ZhiYuCore/OAuth/CodexResponsesProvider.swift` | **直接复用** | 走订阅额度的 Provider。 |
| `ZhiYu/OAuth/CodexLoginService.swift` | **直接复用** | 回环 OAuth（端口 1455）；仅日志文案"知语"→"SayIt"。 |
| `ZhiYu/Secrets/KeychainStore.swift` | **需通用化改造** | `service` 由 `com.liuwentong.ZhiYu` → `com.liuwentong.SayIt`；account 名沿用。 |
| `ZhiYu/LLM/ProviderFactory.swift` | **需通用化改造** | 数据驱动构造逻辑保留；按 SayIt 的 ProviderKind 子集裁剪（润色不必支持 6 家全集，但结构照搬）。 |
| `ZhiYu/Config/AppConfig.swift` | **需通用化改造** | 保留 providerKind/model/style/triggerKey 的 UserDefaults 模式；删除微信特有项（autoOnNewMessage 等），新增 STT 路选择、是否润色、按住/双击模式等。 |
| `ZhiYu/Input/{ModifierDoubleTap,TriggerKey}.swift` + `ZhiYuCore/Input/DoubleTapDetector.swift` | **需通用化改造** | DoubleTapDetector（纯逻辑+已有测试）直接复用；ModifierDoubleTap 改造为 HotkeyManager：在双击检测之外**新增"按住/松手"边沿检测**（flagsChanged 的 press/release）。 |
| `ZhiYu/Permissions/AccessibilityAuthorizer.swift` | **直接复用** | AX 权限检查/申请/跳转设置。 |
| `ZhiYu/Probe/InserterProbe.swift`（CGEvent + AX 写值）| **需通用化改造** | 抽取其 CGEvent 按键投递（`postKey` / `CGEventSource`）与 AX `AXUIElementSetAttributeValue` 写值模式，用于 TextInjector；去掉所有微信专有的 composer 定位逻辑，改为对"系统当前聚焦元素"操作。 |
| `ZhiYu/Panel/CandidatePanelController.swift`（NSPanel 模式）| **需通用化改造** | 借鉴其 borderless / `.nonactivatingPanel` / `.floating` / `orderFrontRegardless` 不抢焦点浮窗模式，用于 RecordingPanel HUD；丢弃候选/会话相关逻辑。 |
| `ZhiYu/AppDelegate.swift` | **需通用化改造** | 保留 accessory 策略 + 单实例 + 启动装监听骨架；触发回调改为 HotkeyManager → DictationCoordinator。 |
| `ZhiYu/ZhiYu.entitlements` | **直接复用（改名）** | App Sandbox 关 + automation.apple-events；SayIt 另需 Hardened Runtime + 麦克风（麦克风走 Info.plist usage description）。 |

**复用结论**：约 70% 的基础设施（Provider/OAuth/Keychain/AX 权限/CGEvent 底层/NSPanel 模式/双击检测/accessory 骨架）可直接或近似复用。SayIt 的全新增量集中在：音频录制、STT 双路、润色提示词与管线、通用文本注入、按住手势。

> 注：ZhiYu 自身用的是**手写 .xcodeproj**（仓库里没有 `project.yml` / `Info.plist`，accessory 策略走运行时 `setActivationPolicy(.accessory)`）。SayIt 改用 XcodeGen，是有意的工程升级，不是照搬。

---

## 5. 端到端数据流

状态机（`DictationCoordinator`）：`idle → recording → transcribing → polishing → injecting → idle`。

```
[用户按住热键]
   │  HotkeyManager 捕获 press 边沿
   ▼
① 记录"目标 App"= 此刻 NSWorkspace.frontmostApplication（松手前聚焦的 App）
② 弹出 RecordingPanel HUD（不抢焦点，.nonactivatingPanel），显示录音中 + 电平
③ AudioRecorder.start()  采集 PCM
   │
[用户松手热键]（或双击 toggle 模式下再按一下）
   │  HotkeyManager 捕获 release 边沿
   ▼
④ AudioRecorder.stop() → audio buffer；HUD 切到"转写中…"
⑤ Transcriber.transcribe(audio)  ── 本地 WhisperKit 或 云端，取决于 AppConfig
   │  失败 → 见第 9 节错误处理
   ▼
⑥ 若启用润色：PolishPipeline.polish(rawText, appName: 目标App名, style)
   │  失败 → 回退使用原始转写文本（不阻断注入）
   │  未启用：直接用原始转写文本
   ▼
⑦ 注入前校验：目标 App 是否仍是前台（frontmostApplication == 记录的目标 App）？
   │  ├─ 是 → TextInjector.inject(text)
   │  │        ├─ AX 写聚焦元素失败 → CGEvent 逐字/粘贴
   │  │        └─ 仍失败 → 写系统剪贴板 + HUD 提示"已复制，⌘V 粘贴"
   │  └─ 否（用户切走了）→ 不强行注入；写剪贴板 + HUD 提示"已复制到剪贴板"
   ▼
⑧ HUD 收起，回到 idle
```

### 5.1 关键约束
- **目标 App 锁定**：在按下瞬间（步骤①）就记录目标 App 与（尽量）聚焦元素，避免转写/润色耗时期间用户切换 App 导致注入到错的窗口。
- **不抢焦点**：HUD 用 `.nonactivatingPanel`，录音/HUD 全程不夺走目标 App 的键盘焦点。
- **注入前二次校验**（步骤⑦）：这是正确性核心。若前台已变，宁可回退剪贴板也不要把文字打进别人的窗口。
- **润色非阻断**：润色失败/超时一律回退原文，绝不让润色环节吞掉用户已经说出来的内容。

---

## 6. 润色提示词设计

润色的本质是**整理，不是回答**。提示词（`PolishPromptBuilder`）需明确约束模型只做"把口述转成成稿"的文字工作，绝不把用户的话当成要回答的问题。

### 6.1 硬约束（System / 指令部分）
1. **只整理不回答**：把输入当作"待整理的口述稿"，输出整理后的文本本身；绝不回答其中的提问、不补充信息、不评论。
2. **去语气词/填充词**：删除"嗯、呃、那个、就是说、um、uh、like、you know"等口水词与无意义重复。
3. **口误自我纠正**：当说话者中途改口（"周二…不对，是周三开会"），保留**最终意图**（周三），丢弃被纠正掉的部分。
4. **补标点与大小写**：按语义补全标点、句首大写（英文）、专有名词大小写。
5. **口述列表自动分点**：当内容呈现枚举/步骤口吻（"第一…第二…还有…"），整理成项目符号或编号列表。
6. **保留中英混合**：原文中英混合就保持中英混合，**不擅自翻译**任何一方。
7. **保留专有名词**：人名、产品名、技术术语、品牌、代码标识符原样保留（含大小写），不"猜测纠错"成别的词。
8. **上下文 App 名**：把目标 App 名（如 "Xcode"/"Mail"/"Slack"）作为上下文提示注入，帮助模型判断语域（写代码注释 vs 写邮件 vs 发消息）。仅作语气/格式参考，不改变上述硬约束。
9. **输出纯净**：只输出整理后的正文，不加前后缀、不加"以下是整理结果"之类的话、不加引号包裹。

### 6.2 预设风格（`PolishStyle`）
| 风格 | 行为 |
|---|---|
| 智能（默认）| 全套整理：去口水词、补标点、改口纠正、必要时分点、按 App 名调语域。 |
| 仅标点 | 只补标点与大小写、去最明显口水词；**不重组句子、不分点、不改措辞**（最保真）。 |
| 正式 | 在"智能"基础上转为书面/正式语域（去口语化、完整句）。 |
| 口语 | 在"智能"基础上保留自然口语节奏（适合发消息/聊天），轻整理。 |

> 自定义风格（用户自填 prompt）可在 v2 加入（复用 ZhiYu AppConfig.customPrompt 模式）。

### 6.3 提示词结构（伪代码）
```
system = 硬约束 1–9 + 当前风格(6.2) 的语域指令
user   = "【当前应用】{appName}\n【口述原文】\n{rawTranscript}"
```
返回模型输出，trim 包裹引号/多余空行后作为成稿。

### 6.4 测试要点（TDD，T6）
- 给定含"嗯/呃/um"的输入 → 输出不含这些词。
- 含改口 → 只保留最终意图。
- 中英混合输入 → 输出仍中英混合（断言未出现整体翻译）。
- 专有名词（如 "WhisperKit"、"M4 Pro"）→ 原样保留。
- "仅标点"风格 → 不分点、不改词序。
- appName 注入到 prompt 字符串中。
- PromptBuilder 是纯函数，不发网络，便于断言。

---

## 7. 配置 / 凭据 / 隐私

### 7.1 配置存储
- 非密钥配置（providerKind、model、STT 路、是否润色、风格、热键、按住/双击模式）→ `UserDefaults`（复用 ZhiYu AppConfig 模式）。
- 密钥/token（API key、ChatGPT OAuthTokens）→ **Keychain**（service `com.liuwentong.SayIt`）。绝不落 UserDefaults / 明文文件 / 日志。

### 7.2 凭据安全（沿用 ZhiYu 已验证实践）
- Keychain 非破坏写（先 update 后 add，写失败保留旧值）。
- OAuth：token 响应解码失败/非 2xx 时**只记状态码，绝不打印响应体**（避免泄露 token）；refresh token 轮换后未落盘则如实失败、不当成功。

### 7.3 隐私
- **本地模式（默认）**：音频在 WhisperKit 本地转写，**音频与文本均不出设备**。润色亦可走本地不可用时才上云——但若润色走云端，需在 UI 标注。
- **云端模式**：UI 明确标注"音频/文本将发送到 {Provider} 处理"，让用户知情选择。STT 与润色的"本地/云端"分别独立标注（可能转写本地但润色云端）。
- 不持久化录音文件：转写完成即释放音频 buffer（除非用户在 v2 开启历史功能）。
- 麦克风权限：Info.plist `NSMicrophoneUsageDescription` 写明用途（"用于语音听写"）。

---

## 8. STT 选型

### 8.1 统一协议
```swift
public protocol Transcriber: Sendable {
    /// 输入：录音音频（PCM/WAV）；输出：转写文本（中英混合原样）。
    func transcribe(audio: AudioBuffer, options: TranscribeOptions) async throws -> String
}
```
- `options` 含语言提示（auto / zh / en / zh-en 混合）、是否带时间戳（v1 不需要）。
- 调用方只依赖协议；本地/云端切换是配置项，不改调用代码。

### 8.2 本地（默认）
- **WhisperKit，模型 large-v3-turbo**。理由：M4 Pro 48GB 足以本地跑 turbo 档，质量/速度平衡好，中英混合表现可用，隐私零外发。
- 模型首次使用时下载并缓存；地基阶段**不引入** WhisperKit 依赖（T8 才接）。

### 8.3 预留
- `Transcriber` 协议预留 **Parakeet / FluidAudio** 等中英方案作为未来本地引擎切换（同协议，新增实现即可）。

### 8.4 云端
- **OpenAI 兼容转写**接口（如 `gpt-4o-mini-transcribe`，或 `whisper-1`）。复用 Provider 网络底座 + Keychain key / ChatGPT OAuth。
- 用于：本地模型未下载完、本地失败、或用户主动选择云端（更快/更省内存）的场景。

### 8.5 选路策略
- 默认：本地 WhisperKit。
- 配置可强制云端，或"本地优先、失败回退云端"（v1 可先做"二选一"，回退留 v2）。

---

## 9. 错误处理与边界

| 场景 | 处理 |
|---|---|
| 未授予麦克风权限 | 首次触发弹系统授权；未授权时 HUD 提示并跳设置；不录音。 |
| 未授予辅助功能（AX）权限 | 注入需要 AX；未授权时 `AccessibilityAuthorizer.promptIfNeeded()`，HUD 提示去开启；可先把成稿写剪贴板兜底。 |
| 录音过短（<约 0.3s）/ 静音 | 视为误触，不转写，静默收 HUD（可轻提示）。 |
| 本地模型未下载完 | HUD 提示"模型准备中"，或按配置回退云端。 |
| STT 失败（异常/超时）| HUD 报错；若配置允许，回退另一路；都失败则收 HUD 不注入。 |
| 转写为空串 | 不进入润色/注入，收 HUD。 |
| 润色失败 / 超时 | **回退使用原始转写文本**注入（润色非阻断）。 |
| 润色返回空 / 明显异常（远长于原文、像在回答）| 回退原文（可加长度/相似度护栏）。 |
| 注入时目标 App 已切走 | 不强注；写剪贴板 + HUD"已复制到剪贴板"。 |
| 目标聚焦元素不可写（只读/无文本框）| AX 失败 → CGEvent 兜底 → 剪贴板兜底。 |
| Provider 未配置 key / OAuth 未登录 | `ProviderError.missingAPIKey`；HUD 提示去设置；若仅润色缺失，可降级为"只注入原始转写"。 |
| 网络/鉴权/限流错误 | 复用 ZhiYu 的 ProviderError → 简洁中文文案映射（401/403 鉴权、429 限流、5xx 服务端）。 |
| 录音中再次触发 / 重入 | HotkeyManager + Coordinator 状态机去重：非 idle 时忽略新的 start，或正确处理 toggle 的 stop。 |
| 单实例 | 复用 ZhiYu：已有实例运行则本次启动退出。 |
| OAuth 端口 1455 被占用 | 复用 ZhiYu CodexLoginService 错误文案。 |

通用原则：**绝不静默丢失用户已说出的内容**——任何后段失败都至少把已转写文本送到剪贴板，并通过 HUD 告知。

---

## 10. v1 范围与路线图

### v1（核心闭环，本 spec 主体）
- 按住 / 双击触发（默认按住）。
- 录音 HUD。
- 本地 WhisperKit large-v3-turbo + 云端 OpenAI 兼容转写（二选一配置）。
- LLM 润色（智能/仅标点/正式/口语 4 风格），ChatGPT OAuth + API key 两种凭据。
- 通用文本注入（AX → CGEvent → 剪贴板）。
- 设置界面 + 权限引导。
- 错误回退闭环。

### v2
- 本地优先、失败自动回退云端（STT 与润色各自）。
- 自定义润色 prompt 风格。
- 听写历史 / 可回看与重新注入。
- Parakeet / FluidAudio 本地引擎切换。
- 每 App 记忆默认风格（写代码 App 默认"正式/原样"等）。
- 多热键 / 自定义热键绑定。

### v3
- 实时 streaming partials（边说边出）。
- 词典 / 个性化术语表（强化专有名词保留）。
- 语音命令（"换行""删除上一句"等编辑指令）。
- iCloud 设置同步。

---

## 11. 任务分层 DAG 与并行编排

### 11.1 任务清单
| ID | 任务 | 产物 | 说明 |
|---|---|---|---|
| T1 | 仓库 + SPM 包 | `SayItCore` 包骨架、`.gitignore` | Package.swift（macOS 14, Swift 6） |
| T2 | XcodeGen App 工程 | `project.yml`、App target 薄壳、Info.plist、entitlements | 依赖本地包 SayItCore；glob 纳源码 |
| T3 | 复制 ZhiYu 可复用模块 | Provider/OAuth/Keychain/AX/DoubleTapDetector | 按第 4 节清单移植+改名 |
| T4 | AppConfig | UserDefaults 配置 | providerKind/model/STT路/润色开关/风格/热键/模式 |
| T5 | Transcriber 协议 + Fake | `Transcriber`、`FakeTranscriber`、`CloudTranscriber` 桩 | TDD |
| T6 | PolishPromptBuilder | 纯函数提示词构造 | TDD（第 6.4 节断言） |
| T7 | PolishPipeline | 调 Provider 润色 + 回退 | TDD（注入 FakeProvider） |
| T8 | WhisperKitTranscriber | 本地 STT 实现 | 引入 WhisperKit 依赖 |
| T9 | AudioRecorder | AVAudioEngine 录音 | 输出 PCM/WAV |
| T10 | TextInjector | AX→CGEvent→剪贴板 注入 | 复用 InserterProbe 底层 |
| T11 | HotkeyManager | 按住 + 双击统一 | 复用 DoubleTapDetector + 新增按住边沿 |
| T12 | RecordingPanel HUD | 不抢焦点浮窗 | 复用 ZhiYu NSPanel 模式 |
| T13 | DictationCoordinator | 端到端状态机 | 串起 T5–T12 |
| T14 | SettingsView | SwiftUI 设置 | Provider/STT/风格/热键/权限/登录 |
| T15 | 错误回退与体验打磨 | 第 9 节闭环 + HUD 文案 | 收尾 |

### 11.2 分层（依赖层级）
```
L0:  T1 → (T2 ∥ T3)
       └ T1 完成后，T2 与 T3 可并行

L1:  T4, T5, T6, T9, T10, T11, T12   ← 7 个并行
       依赖：均依赖 L0（工程能编译 + 复用模块到位）
       - T4  依赖 T3（复用 AppConfig/TriggerKey 模式）
       - T5  依赖 T1（Core 包）
       - T6  依赖 T1（Core 包）
       - T9  依赖 T2（App 层 + 麦克风权限）
       - T10 依赖 T2 + T3（InserterProbe 底层）
       - T11 依赖 T2 + T3（DoubleTapDetector）
       - T12 依赖 T2（App 层 NSPanel）

L2:  T7, T8, T14   ← 3 个并行
       - T7  依赖 T5(协议)+T6(提示词)+T3(Provider)
       - T8  依赖 T5(协议)+T9(音频格式) → 引入 WhisperKit
       - T14 依赖 T4(AppConfig)+T3(OAuth/Provider)

L3:  T13   端到端编排，依赖 L1+L2 全部（T5–T12 + T7/T8/T14 的产物）

L4:  T15   错误回退 + 打磨，依赖 T13
```

### 11.3 并行编排策略
- **关键路径**：`T1 → T2 → T9 → T8 → T13 → T15`（音频 → 本地 STT → 编排 → 打磨）。WhisperKit（T8）是最重的外部依赖，尽早在 L2 启动。
- **L1 最大并行度 = 7**：T4/T5/T6/T9/T10/T11/T12 互不依赖，适合用 `dispatching-parallel-agents` 分派多个 subagent 并行实现（各自带 TDD/编译验证）。
- **TDD 优先项**：T5/T6/T7 是纯逻辑、可在 SayItCore 内单测，先于 UI/系统胶水落地，给 T13 提供已验证的内核。
- **可单独验证的边界**：
  - SayItCore：`swift build --package-path SayItCore` + `swift test`（覆盖 T5/T6/T7、复用的 OAuth/Provider 测试）。
  - App：`xcodegen` 生成 + `xcodebuild ... -scheme SayIt build`。
- **集成顺序建议**：先 T13 用 FakeTranscriber + FakeProvider 跑通整条状态机（不依赖 WhisperKit/真实网络），再把 T8/T7 的真实实现接入——这样端到端骨架不被外部依赖阻塞。

---

## 12. 风险与对策

| 风险 | 影响 | 对策 |
|---|---|---|
| WhisperKit 模型大、首次下载慢/失败 | 首次体验差 | 后台预下载 + 进度 HUD；下载完成前回退云端或提示；模型缓存复用。 |
| 本地转写延迟（large-v3-turbo 仍有秒级）| 端到端慢 | turbo 档已选最快；先转写后润色、润色可关；v3 再上 streaming。 |
| 中英混合转写质量 | 核心卖点不稳 | large-v3-turbo 多语；预留 Parakeet/FluidAudio 切换；润色层补救（保留专名/不翻译）。 |
| 润色把口述当问题回答 | 注入错误内容 | 提示词硬约束"只整理不回答"+ 长度/相似度护栏；异常回退原文。 |
| 注入兼容性（不同 App 的文本框差异大）| 部分 App 注入失败 | 三级兜底 AX→CGEvent→剪贴板；剪贴板永远兜底不丢内容。 |
| 注入到错误窗口（耗时期间切走）| 隐私/误操作 | 按下即锁目标 App，注入前二次校验前台一致，不一致退剪贴板。 |
| AX / 麦克风权限被拒 | 无法工作 | 权限引导 UI + 跳转系统设置；剪贴板兜底让"至少能复制"。 |
| App Sandbox 关闭导致上架受限 | 分发渠道 | 走 Developer ID + 公证（非 MAS），开源自编译；与 Typeless 同路径。 |
| ChatGPT OAuth 协议/端点变化 | 登录失效 | 协议常量集中在 ChatGPTOAuth（单一真相源）；失败有清晰文案；可回退 API key。 |
| 全局热键与其它 app 冲突 | 误触/抢键 | 默认选不常用修饰键双击 + 按住；v2 支持自定义绑定。 |
| 录音/HUD 抢焦点破坏目标编辑态 | 注入失败 | HUD 用 `.nonactivatingPanel`，全程不夺焦点。 |
| 重入 / 状态竞争（录音中再触发）| 状态错乱 | Coordinator 显式状态机 + HotkeyManager 去重；generation token 模式（借鉴 ZhiYu）。 |
| Swift 6 严格并发（Sendable/actor 隔离）| 编译/数据竞争 | 协议标 `Sendable`；UI/系统胶水 `@MainActor`；复用 ZhiYu 已通过 Swift6 的并发模式。 |

---

（完）
