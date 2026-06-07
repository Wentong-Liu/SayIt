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

    /// 润色阶段的预期时长（秒）。进度条用它作为 50%→90% 缓动爬升的时间窗，
    /// 也是「比往常要长」文案的触发阈值：超过此时长仍未拿到润色结果即翻文案。
    private static let expectedPolishDuration: Double = 3
    /// 润色阶段进度条的爬升上限（占比）。爬到 90% 后保持，绝不在拿到真实结果前越过此线。
    private static let polishProgressCap: CGFloat = 0.9
    /// 拿到润色结果后由当前位置吸附到 100% 的吸附动画时长（秒）。
    private static let snapDuration: Double = 0.3

    @ObservedObject var model: RecordingPanelModel
    @State private var appeared = false
    /// 持续旋转的相位，驱动识别态的环形进度动画。
    @State private var spin = false

    /// 进度条当前展示值（0...1）：润色阶段由客户端定时缓动驱动（与后端解耦），
    /// 而非直接绑定后端发布的离散值（后端仅发 0.5 起、1.0 完成两点）。
    @State private var displayedProgress: CGFloat = 0
    /// 本轮润色起算时刻；`nil` 表示尚未进入润色阶段。用于判定是否超过预期时长。
    @State private var polishStartedAt: Date?
    /// 润色是否已超过 `expectedPolishDuration` 仍未返回：为真时主文案翻成「比往常要长」。
    @State private var polishElapsedLong = false
    /// 驱动「比往常要长」文案翻转的延时任务句柄；润色完成 / 离开处理态时取消。
    @State private var longLabelTask: Task<Void, Never>?

    public init(model: RecordingPanelModel) {
        self.model = model
    }

    public var body: some View {
        HStack(spacing: 12) {
            indicator
            Text(statusText)
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
            // 首帧若已处于处理态（例如 HUD 在 .processing 时才挂载），同步驱动一次。
            handleStateChange(model.state)
        }
        .onChange(of: model.state) { _, newState in
            handleStateChange(newState)
        }
        .onDisappear {
            // 视图卸载：取消挂起的文案翻转任务，避免悬挂的 Task 在下一轮误触发。
            longLabelTask?.cancel()
            longLabelTask = nil
        }
    }

    /// HUD 主文案：润色阶段一旦超过预期时长（`polishElapsedLong`），就地替换成「比往常要长」；
    /// 其余情况沿用 ``RecordingState/displayText``（识别/润色的常规文案与 info/error 文案均不变）。
    private var statusText: String {
        if polishElapsedLong, model.state.processingPhase == .polishing {
            return RecordingState.takingLongerMessage
        }
        return model.state.displayText
    }

    /// 响应状态变化，驱动进度条的客户端缓动与「比往常要长」文案翻转（与后端解耦）。
    ///
    /// 时间线（聚焦润色）：后端在识别完成时发布 `0.5 + .polishing`，本方法据此把展示值在
    /// `expectedPolishDuration` 内以 `.easeOut` 缓动爬到 `polishProgressCap`(90%) 并自然保持；
    /// 同时起一个延时任务，超过预期时长仍未返回则翻文案。后端在润色返回时发布 `1.0`，
    /// 本方法据此把展示值吸附到 100% 并清理计时；离开处理态则把所有状态复位，保证下一轮干净起步。
    private func handleStateChange(_ state: RecordingState) {
        switch (state.processingPhase, state.progress) {
        case (.transcribing?, let progress?):
            // 识别阶段：直接跟随后端发布值（0.0 起步），交由进度条的既有缓动平滑过渡。
            resetPolishTracking()
            withAnimation(.easeInOut(duration: Self.snapDuration)) {
                displayedProgress = CGFloat(min(max(progress, 0), 1))
            }
        case (.polishing?, let progress?):
            if progress >= 1.0 {
                // 润色返回：从当前位置（≤90%）吸附到 100%，并取消「比往常要长」计时。
                longLabelTask?.cancel()
                longLabelTask = nil
                withAnimation(.easeInOut(duration: Self.snapDuration)) {
                    displayedProgress = 1.0
                }
            } else if polishStartedAt == nil {
                // 润色起步：从 50% 起以 ease-out 在 expectedPolishDuration 内爬到 90% 并保持。
                beginPolishTrickle(from: CGFloat(min(max(progress, 0), 1)))
            }
        default:
            // 离开处理态（idle/info/error/listening/transcribing-旧态）：复位，为下一轮做准备。
            resetPolishTracking()
            displayedProgress = 0
        }
    }

    /// 起步润色缓动：把展示值从起点（~50%）以 `.easeOut` 在预期时长内爬到 90% 上限并保持，
    /// 同时排程一个延时任务——超过预期时长仍处于润色阶段则翻「比往常要长」文案。
    private func beginPolishTrickle(from start: CGFloat) {
        polishStartedAt = Date()
        polishElapsedLong = false
        displayedProgress = start
        withAnimation(.easeOut(duration: Self.expectedPolishDuration)) {
            displayedProgress = Self.polishProgressCap
        }
        longLabelTask?.cancel()
        longLabelTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.expectedPolishDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // 仍在润色阶段（未返回结果）才翻文案；否则保持常规文案。
            if model.state.processingPhase == .polishing,
               (model.state.progress ?? 1) < 1.0 {
                polishElapsedLong = true
            }
        }
    }

    /// 复位润色相关的计时与文案状态，并取消挂起的延时任务。
    private func resetPolishTracking() {
        longLabelTask?.cancel()
        longLabelTask = nil
        polishStartedAt = nil
        polishElapsedLong = false
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
    /// 填充宽度绑定客户端展示值 `displayedProgress`（由 `handleStateChange` 驱动），而非后端发布的离散值：
    /// 润色阶段从 50% 以 ease-out 在 `expectedPolishDuration` 内缓动爬到 90% 上限并保持，
    /// 拿到真实结果后再吸附到 100%——绝不停在 50%，等待发生在 90% 上限附近。
    /// 前景色随阶段切换以在 50% 边界强化「识别 → 润色」的相位变化。
    private func progressBar(progress: Double, phase: RecordingState.ProcessingPhase) -> some View {
        let fillColor: Color = (phase == .polishing)
            ? Color.green.opacity(0.9)   // 润色：绿色
            : Color.white.opacity(0.9)   // 识别：白色
        let fill = min(max(displayedProgress, 0), 1)
        return ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.white.opacity(0.2))
                .frame(width: Self.progressBarWidth, height: Self.progressBarHeight)
            Capsule()
                .fill(fillColor)
                .frame(width: Self.progressBarWidth * fill, height: Self.progressBarHeight)
        }
        .frame(width: Self.progressBarWidth, height: Self.progressBarHeight)
    }
}
#endif
