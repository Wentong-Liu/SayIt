#if canImport(SwiftUI)
import SwiftUI

/// 听写 HUD 的视图模型：控制器写入状态/音量，视图观察后刷新。
///
/// `level` 是 0...1 的归一化输入电平，仅在 `.listening` 态用于驱动波形指示；其余状态忽略。
@MainActor
public final class RecordingPanelModel: ObservableObject {
    /// 当前听写状态。
    @Published public var state: RecordingState = .idle
    /// 归一化输入电平（0...1），驱动聆听态的波形/音量指示。
    @Published public var level: Double = 0

    public init(state: RecordingState = .idle, level: Double = 0) {
        self.state = state
        self.level = level
    }
}

/// 听写 HUD 的 SwiftUI 内容（被 `NSHostingView` 包装进 borderless 透明面板）。
///
/// 暗色胶囊卡片：左侧随状态切换的图标/波形指示，右侧主文案。控制器据此测自然尺寸并定位。
public struct RecordingPanelView: View {
    /// 卡片四周透明外边距：给阴影留渲染空间，避免直角透明窗口四角被裁成色块。
    /// 控制器据此补偿定位与尺寸，故卡片视觉位置不变。需 ≥ 阴影外扩范围。
    public static let shadowPad: CGFloat = 16

    /// 卡片圆角（胶囊感）。
    private static let cornerRadius: CGFloat = 16
    /// 波形条数量。
    private static let barCount = 5
    /// 处理态进度条轨道宽度（pt）。
    private static let progressBarWidth: CGFloat = 48
    /// 处理态进度条高度（pt）。
    private static let progressBarHeight: CGFloat = 5

    @ObservedObject var model: RecordingPanelModel
    @State private var appeared = false
    /// 持续旋转的相位，驱动识别态的环形进度动画。
    @State private var spin = false

    public init(model: RecordingPanelModel) {
        self.model = model
    }

    public var body: some View {
        HStack(spacing: 12) {
            indicator
            Text(model.state.displayText)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.95))
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                        .fill(Color.black.opacity(0.55))
                )
        )
        .environment(\.colorScheme, .dark)
        .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
        .padding(Self.shadowPad)
        .scaleEffect(appeared ? 1 : 0.92)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { appeared = true }
            spin = true
        }
    }

    /// 左侧状态指示：聆听=波形、识别=旋转环、出错=红色感叹号。
    @ViewBuilder private var indicator: some View {
        switch model.state {
        case .listening:
            waveform
        case .transcribing:
            spinner
        case .processing(let progress, let phase):
            progressBar(progress: progress, phase: phase)
        case .info:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.green.opacity(0.9))
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.red.opacity(0.9))
        case .idle:
            // idle 通常不展示；给一个静态点位避免布局塌缩。
            Circle().fill(Color.white.opacity(0.5)).frame(width: 8, height: 8)
        }
    }

    /// 音量波形：每条高度由归一化电平加上相位偏移驱动，呈现起伏的听感。
    private var waveform: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<Self.barCount, id: \.self) { i in
                Capsule()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 3, height: barHeight(index: i))
                    .animation(.easeOut(duration: 0.12), value: model.level)
            }
        }
        .frame(width: 24, height: 18)
    }

    /// 第 i 条波形的高度：基线 + 电平 * 幅度，并按索引做对称凸起（中间高、两侧低）。
    private func barHeight(index i: Int) -> CGFloat {
        let baseline: CGFloat = 4
        let span: CGFloat = 14
        // 中间条权重最高，向两侧递减，形成对称波形外观。
        let mid = Double(Self.barCount - 1) / 2
        let distance = abs(Double(i) - mid)
        let weight = 1.0 - distance / (mid + 1)
        let clamped = min(max(model.level, 0), 1)
        return baseline + span * CGFloat(clamped * weight)
    }

    /// 识别态旋转进度环。
    private var spinner: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .frame(width: 16, height: 16)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)
    }

    /// 处理态进度条（Typeless 风格）：固定宽度轨道 + 按进度填充的前景胶囊。
    /// 进度在阶段边界阶梯式推进（0→0.5→1.0），靠 `.animation` 让填充宽度平滑滑动，观感连续。
    /// 前景色随阶段切换以在 50% 边界强化「识别 → 润色」的相位变化。
    private func progressBar(progress: Double, phase: RecordingState.ProcessingPhase) -> some View {
        let clamped = min(max(progress, 0), 1)
        let fillColor: Color = (phase == .polishing)
            ? Color.green.opacity(0.9)   // 润色：绿色
            : Color.white.opacity(0.9)   // 识别：白色
        return ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.white.opacity(0.2))
                .frame(width: Self.progressBarWidth, height: Self.progressBarHeight)
            Capsule()
                .fill(fillColor)
                .frame(width: Self.progressBarWidth * CGFloat(clamped), height: Self.progressBarHeight)
                .animation(.easeInOut(duration: 0.3), value: clamped)
        }
        .frame(width: Self.progressBarWidth, height: Self.progressBarHeight)
    }
}
#endif
