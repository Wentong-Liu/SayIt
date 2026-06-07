import Foundation

/// 听写 HUD 的展示状态。
///
/// 控制器把当前听写阶段映射到此枚举，视图据此切换图标/文案/动画：
/// - `idle`：空闲（HUD 通常隐藏；保留此态便于状态机收敛与测试）。
/// - `listening`：正在录音 / 聆听用户说话。
/// - `transcribing`：录音结束、正在识别转文字。
/// - `error`：出错，携带面向用户的简短文案。
public enum RecordingState: Equatable, Sendable {
    case idle
    case listening
    case transcribing
    case error(String)

    /// HUD 在该状态下展示的主文案（默认中文，对齐项目其它 UI 文案风格）。
    public var displayText: String {
        switch self {
        case .idle:
            return "准备就绪"
        case .listening:
            return "聆听中…"
        case .transcribing:
            return "识别中…"
        case .error(let message):
            // 出错文案：空消息兜底成通用提示，避免 HUD 出现空白。
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "出错了" : trimmed
        }
    }

    /// 该状态是否应让 HUD 保持可见。`idle` 不展示，其余皆展示。
    public var isVisible: Bool {
        self != .idle
    }
}
