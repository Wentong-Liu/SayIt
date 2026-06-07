import Foundation

/// 听写 HUD 的展示状态。
///
/// 控制器把当前听写阶段映射到此枚举，视图据此切换图标/文案/动画：
/// - `idle`：空闲（HUD 通常隐藏；保留此态便于状态机收敛与测试）。
/// - `listening`：正在录音 / 聆听用户说话。
/// - `transcribing`：录音结束、正在识别转文字。
/// - `info`：中性提示（如「已粘贴到当前窗口」），携带简短文案；非错误，用对勾图标。
/// - `error`：出错，携带面向用户的简短文案。
public enum RecordingState: Equatable, Sendable {
    case idle
    case listening
    case transcribing
    case info(String)
    case error(String)

    /// HUD 在该状态下展示的主文案。固定态走包内本地化（`Bundle.module`，en + zh-Hans）；
    /// `info`/`error` 携带的具体文案由调用方传入（已是其语言），仅在为空时兜底为本地化通用提示。
    public var displayText: String {
        switch self {
        case .idle:
            return Self.localized("hud.idle", fallback: "Ready")
        case .listening:
            return Self.localized("hud.listening", fallback: "Listening…")
        case .transcribing:
            return Self.localized("hud.transcribing", fallback: "Transcribing…")
        case .info(let message):
            // 中性提示：空消息兜底成通用提示，避免 HUD 出现空白。
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? Self.localized("hud.done", fallback: "Done") : trimmed
        case .error(let message):
            // 出错文案：空消息兜底成通用提示，避免 HUD 出现空白。
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? Self.localized("hud.error", fallback: "Something went wrong") : trimmed
        }
    }

    /// 从包内 `Localizable.xcstrings` 取本地化文案；缺失时回落到英文兜底，保证不空白。
    private static func localized(_ key: String, fallback: String) -> String {
        String(localized: String.LocalizationValue(key), bundle: .module, comment: "Recording HUD state text")
            .nonKeyOr(fallback, key: key)
    }

    /// 该状态是否应让 HUD 保持可见。`idle` 不展示，其余皆展示。
    public var isVisible: Bool {
        self != .idle
    }

    /// 「本地模型尚未下载就绪」时面向用户的本地化提示文案（en + zh-Hans，走包内 `Bundle.module`）。
    ///
    /// 不新增枚举 case（避免牵动 ``RecordingPanelView`` 的穷举 switch）：由调用方包进现成的
    /// `.error(_:)`/`.info(_:)` 态展示。当本地模型未缓存时，本地转写底层会先触发下载（可能耗时数分钟），
    /// 期间 HUD 会一直停在「识别中」表现为卡死；上层据此**在转写前**就给出本提示并收敛，
    /// 引导用户等待下载完成或切换到云端。
    public static var modelNotReadyMessage: String {
        localized("hud.modelNotReady",
                  fallback: "Local model still downloading — please wait or switch to cloud")
    }
}

private extension String {
    /// 本地化查不到键时，`String(localized:)` 会原样返回键名；此时回落到英文兜底。
    func nonKeyOr(_ fallback: String, key: String) -> String {
        self == key ? fallback : self
    }
}
