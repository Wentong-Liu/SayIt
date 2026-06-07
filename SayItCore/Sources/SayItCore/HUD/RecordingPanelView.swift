#if canImport(SwiftUI)
import Foundation
import SwiftUI

/// The dictation HUD's view model: the controller writes state/volume, the view observes and refreshes.
///
/// `level` is the 0...1 normalized input level, used only in the `.listening` state to drive the waveform indicator; ignored in other states.
@MainActor
public final class RecordingPanelModel: ObservableObject {
    /// The current dictation state.
    @Published public var state: RecordingState = .idle
    /// Normalized input level (0...1), driving the waveform/volume indicator in the listening state.
    @Published public var level: Double = 0

    public init(state: RecordingState = .idle, level: Double = 0) {
        self.state = state
        self.level = level
    }
}

/// The dictation HUD's SwiftUI content (wrapped by `NSHostingView` into a borderless transparent panel).
///
/// A dark capsule card: an icon/waveform indicator on the left that switches with state, and primary copy on the right. The controller measures the natural size and positions accordingly.
public struct RecordingPanelView: View {
    /// Transparent outer margin around the card: leaves rendering space for the shadow, avoiding the corners of the square transparent window being clipped into color blocks.
    /// The controller compensates positioning and size accordingly, so the card's visual position is unchanged. Must be >= the shadow's outward extent.
    public static let shadowPad: CGFloat = 16

    /// Card corner radius (capsule feel).
    private static let cornerRadius: CGFloat = 16
    /// Number of waveform bars.
    private static let barCount = 5
    /// Track width (pt) of the processing-state progress bar.
    private static let progressBarWidth: CGFloat = 48
    /// Height (pt) of the processing-state progress bar.
    private static let progressBarHeight: CGFloat = 5

    /// The expected duration (seconds) of the polish phase. The progress bar uses it as the time window for the 50%->90% eased climb,
    /// and it is also the trigger threshold for the "taking longer than usual" copy: if the polish result is still not received after this duration, the copy flips.
    private static let expectedPolishDuration: Double = 3
    /// The climb ceiling (fraction) of the polish-phase progress bar. After climbing to 90% it holds, never crossing this line before the real result arrives.
    private static let polishProgressCap: CGFloat = 0.9
    /// The duration (seconds) of the snap animation from the current position to 100% after the polish result arrives.
    private static let snapDuration: Double = 0.3

    @ObservedObject var model: RecordingPanelModel
    @State private var appeared = false
    /// The continuously rotating phase, driving the transcribing-state ring progress animation.
    @State private var spin = false

    /// The progress bar's current displayed value (0...1): in the polish phase it is driven by a client-side timed ease (decoupled from the backend),
    /// rather than directly bound to the discrete values published by the backend (the backend only emits two points: 0.5 at start, 1.0 at completion).
    @State private var displayedProgress: CGFloat = 0
    /// The start time of this polish round; `nil` means the polish phase has not been entered yet. Used to decide whether the expected duration has been exceeded.
    @State private var polishStartedAt: Date?
    /// Whether polish has exceeded `expectedPolishDuration` without returning: when true the primary copy flips to "taking longer than usual".
    @State private var polishElapsedLong = false
    /// The handle of the delayed task that drives the "taking longer than usual" copy flip; cancelled when polish completes / the processing state is left.
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
            // If the first frame is already in the processing state (e.g. the HUD is mounted only at .processing), drive it once synchronously.
            handleStateChange(model.state)
        }
        .onChange(of: model.state) { _, newState in
            handleStateChange(newState)
        }
        .onDisappear {
            // View teardown: cancel the pending copy-flip task, to avoid a dangling Task triggering erroneously in the next round.
            longLabelTask?.cancel()
            longLabelTask = nil
        }
    }

    /// HUD primary copy: in the polish phase, once the expected duration is exceeded (`polishElapsedLong`), replace in place with "taking longer than usual";
    /// otherwise reuse ``RecordingState/displayText`` (the regular transcribing/polish copy and info/error copy are all unchanged).
    private var statusText: String {
        if polishElapsedLong, model.state.processingPhase == .polishing {
            return RecordingState.takingLongerMessage
        }
        return model.state.displayText
    }

    /// Responds to state changes, driving the client-side ease of the progress bar and the "taking longer than usual" copy flip (decoupled from the backend).
    ///
    /// Timeline (focused on polish): the backend publishes `0.5 + .polishing` when transcription completes; this method accordingly climbs the displayed value within
    /// `expectedPolishDuration` with an `.easeOut` ease to `polishProgressCap` (90%) and naturally holds;
    /// it also starts a delayed task that flips the copy if the expected duration is exceeded without a return. The backend publishes `1.0` when polish returns,
    /// and this method accordingly snaps the displayed value to 100% and clears the timer; on leaving the processing state it resets all state, ensuring a clean start next round.
    private func handleStateChange(_ state: RecordingState) {
        switch (state.processingPhase, state.progress) {
        case (.transcribing?, let progress?):
            // Transcription phase: directly follow the backend-published value (starting at 0.0), letting the progress bar's existing ease smooth the transition.
            resetPolishTracking()
            withAnimation(.easeInOut(duration: Self.snapDuration)) {
                displayedProgress = CGFloat(min(max(progress, 0), 1))
            }
        case (.polishing?, let progress?):
            if progress >= 1.0 {
                // Polish returned: snap from the current position (<=90%) to 100%, and cancel the "taking longer than usual" timer.
                longLabelTask?.cancel()
                longLabelTask = nil
                withAnimation(.easeInOut(duration: Self.snapDuration)) {
                    displayedProgress = 1.0
                }
            } else if polishStartedAt == nil {
                // Polish start: climb from 50% with ease-out to 90% within expectedPolishDuration and hold.
                beginPolishTrickle(from: CGFloat(min(max(progress, 0), 1)))
            }
        default:
            // Leaving the processing state (idle/info/error/listening/transcribing-old-state): reset, preparing for the next round.
            resetPolishTracking()
            displayedProgress = 0
        }
    }

    /// Polish-start ease: climb the displayed value from the start point (~50%) with `.easeOut` within the expected duration to the 90% ceiling and hold,
    /// and schedule a delayed task -- if still in the polish phase after the expected duration, flip to the "taking longer than usual" copy.
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
            // Only flip the copy if still in the polish phase (no result returned); otherwise keep the regular copy.
            if model.state.processingPhase == .polishing,
               (model.state.progress ?? 1) < 1.0 {
                polishElapsedLong = true
            }
        }
    }

    /// Resets the polish-related timer and copy state, and cancels the pending delayed task.
    private func resetPolishTracking() {
        longLabelTask?.cancel()
        longLabelTask = nil
        polishStartedAt = nil
        polishElapsedLong = false
    }

    /// Left-side state indicator: listening = waveform, transcribing = rotating ring, error = red exclamation mark.
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
            // idle is usually not displayed; give a static dot to avoid layout collapse.
            Circle().fill(Color.white.opacity(0.5)).frame(width: 8, height: 8)
        }
    }

    /// Volume waveform: 5 dots rise and fall with the live microphone level (voice-driven, like Typeless); when silent it degrades to a gentle breathing fluctuation rather than going dead.
    ///
    /// Uses `TimelineView(.animation)` to re-render every frame, driving a continuous "idle breathing" phase (low amplitude, staggered per bar),
    /// then superimposes a "voice-driven amplitude" term determined by `model.level` -- when speaking the voice-driven term dominates and the dots bounce noticeably, when silent only the breathing wave remains.
    /// Instantaneous changes in `model.level` are still smoothed with `.easeOut`, making the dots respond sensitively to speech without jitter.
    private var waveform: some View {
        TimelineView(.animation) { timeline in
            // Continuous phase (seconds): drives idle breathing; TimelineView advances it frame by frame, no @State timer needed.
            let phase = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<Self.barCount, id: \.self) { i in
                    Capsule()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 3, height: barHeight(index: i, phase: phase))
                        .animation(.easeOut(duration: 0.12), value: model.level)
                }
            }
        }
        .frame(width: 24, height: 18)
    }

    /// Height of the i-th waveform bar = baseline + voice-driven amplitude term + idle breathing term, finally clamped to `baseline ... baseline + span`.
    ///
    /// - Voice-driven amplitude term: `span * level * weight`, with a symmetric bulge by index (high in the middle, low on the sides), bouncing with speech amplitude.
    /// - Idle breathing term: a low-amplitude sine wave, each bar with its own phase offset (staggered), so even when `level ~= 0` the dots gently fluctuate;
    ///   its weight decays as `level` rises, ensuring the voice-driven term dominates when speaking and is not diluted by the breathing wave.
    private func barHeight(index i: Int, phase: Double) -> CGFloat {
        let baseline: CGFloat = 4
        let span: CGFloat = 14
        // The middle bar has the highest weight, decreasing toward the sides, forming a symmetric waveform appearance.
        let mid = Double(Self.barCount - 1) / 2
        let distance = abs(Double(i) - mid)
        let weight = 1.0 - distance / (mid + 1)
        let level = min(max(model.level, 0), 1)

        // Voice-driven amplitude term: rises and falls with the speech level.
        let amplitude = level * weight

        // Idle breathing term: a continuous sine wave, staggered per bar; the main "alive" signal when silent, decaying with the level to yield when speaking.
        let idleSpeed = 2.4            // breathing frequency (rad/s coefficient)
        let idlePhaseStep = 0.9        // phase difference between adjacent bars, forming a traveling wave
        let idleMaxFraction = 0.16     // max fraction of span for the idle fluctuation (low amplitude, gentle breathing only)
        let wave = (Foundation.sin(phase * idleSpeed + Double(i) * idlePhaseStep) + 1) / 2  // 0...1
        let idle = idleMaxFraction * wave * (1 - level)

        let fraction = min(max(amplitude + idle, 0), 1)
        return baseline + span * CGFloat(fraction)
    }

    /// The transcribing-state rotating progress ring.
    private var spinner: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .frame(width: 16, height: 16)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)
    }

    /// Processing-state progress bar (Typeless style): a fixed-width track + a foreground capsule filled by progress.
    /// The fill width is bound to the client-side displayed value `displayedProgress` (driven by `handleStateChange`), not the discrete values published by the backend:
    /// in the polish phase it eases from 50% with ease-out within `expectedPolishDuration` to the 90% ceiling and holds,
    /// then snaps to 100% after the real result arrives -- never stopping at 50%; the wait happens near the 90% ceiling.
    /// The foreground color switches with the phase to reinforce the "transcribing -> polish" phase change at the 50% boundary.
    private func progressBar(progress: Double, phase: RecordingState.ProcessingPhase) -> some View {
        let fillColor: Color = (phase == .polishing)
            ? Color.green.opacity(0.9)   // polish: green
            : Color.white.opacity(0.9)   // transcribing: white
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
