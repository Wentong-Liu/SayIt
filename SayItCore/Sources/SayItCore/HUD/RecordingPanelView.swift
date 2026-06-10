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

    /// The client-side ramp time window (seconds) for the whole processing run. The progress bar uses it as the duration of the single 0%->90% eased climb,
    /// and it is also the trigger threshold for the "taking longer than usual" copy: if the final result is still not received after this duration, the copy flips.
    private static let processingRampDuration: Double = 3
    /// The climb ceiling (fraction) of the processing-state progress bar. After climbing to 90% it holds, never crossing this line before the final result arrives.
    private static let processingProgressCap: CGFloat = 0.9
    /// The duration (seconds) of the snap animation from the current position to 100% after the final result arrives.
    private static let snapDuration: Double = 0.3

    @ObservedObject var model: RecordingPanelModel
    @State private var appeared = false
    /// The continuously rotating phase, driving the transcribing-state ring progress animation.
    @State private var spin = false

    /// The progress bar's current displayed value (0...1): driven by a single client-side timed ease (decoupled from the backend).
    /// On entering the processing state it climbs from 0 with a single ease-out to 90% and holds, only snapping to 100% once the final result arrives;
    /// the discrete values the backend publishes mid-stream (e.g. 0.5 at transcription completion) never touch this value -- the client-side ease owns the progress bar exclusively.
    @State private var displayedProgress: CGFloat = 0
    /// The start time of this processing round; `nil` means this round has not started ramping yet (set on the first entry into `.processing`).
    /// Used to decide whether the expected duration has been exceeded, and to guarantee the single ramp starts only once (a mid-stream phase switch does not restart it).
    @State private var processingStartedAt: Date?
    /// Whether processing has exceeded `processingRampDuration` without returning a final result: when true the primary copy flips to "taking longer than usual".
    @State private var processingElapsedLong = false
    /// The handle of the delayed task that drives the "taking longer than usual" copy flip; cancelled when the final result arrives / the processing state is left.
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

    /// HUD primary copy: once processing holds at the 90% ceiling and exceeds the expected duration (`processingElapsedLong`),
    /// it replaces in place with "taking longer than usual" regardless of the current phase (transcribing / polish); otherwise it reuses
    /// ``RecordingState/displayText`` -- which already returns the Transcribing… / Polishing… copy per phase,
    /// i.e. the "transcribing vs polish" distinction is carried entirely by the copy and the progress-bar position takes no part. The info/error copy is also unchanged.
    private var statusText: String {
        Self.statusText(for: model.state, processingElapsedLong: processingElapsedLong)
    }

    /// Pure decision for the HUD's primary copy, factored out of the computed property so it is directly unit-testable
    /// (the same extract-for-testing pattern as ``RecordingState/displayText`` and `WhisperKitTranscriber.promptText`).
    ///
    /// The "taking longer than usual" swap applies ONLY to the actual transcribing/polishing phases. The `.preparingModel`
    /// phase (cold CoreML load) must keep showing "Preparing model…" the whole time — NEVER swapping to the alarming
    /// "taking longer" copy — because a first-ever ANE compile legitimately takes a while and the upper layer bounds that
    /// wait separately. Excluding `.preparingModel` here leaves the transcribing/polishing swap byte-identical.
    static func statusText(for state: RecordingState, processingElapsedLong: Bool) -> String {
        if processingElapsedLong,
           let phase = state.processingPhase,
           phase != .preparingModel {
            return RecordingState.takingLongerMessage
        }
        return state.displayText
    }

    /// Responds to state changes, driving the single client-side ease of the progress bar and the "taking longer than usual" copy flip (decoupled from the backend).
    ///
    /// The progress bar is one 0%->90% single ease-out spanning the whole processing run, independent of the phase:
    /// - First entry into `.processing` (any phase) -> `beginProcessingRamp()`: climbs from 0 to
    ///   `processingProgressCap` (90%) within `processingRampDuration` (~3s) and holds;
    ///   it also starts a delayed task that flips to the "taking longer than usual" copy if the expected duration is exceeded without a final result.
    /// - Backend publishes the final result (progress >= 1.0) -> cancel the timer and snap the displayed value to 100%.
    /// - Mid-stream discrete updates (e.g. 0.5 at transcription completion) -> do not touch the progress bar: the single client-side ease owns the bar exclusively,
    ///   the phase boundary (50%) never anchors the bar position; the phase only selects the copy via ``statusText``.
    /// - Leaving the processing state -> reset all timer and copy state, ensuring a clean start from 0 next round.
    private func handleStateChange(_ state: RecordingState) {
        switch (state.processingPhase, state.progress) {
        case (_?, let progress?):
            // Processing state (any phase). The progress bar only looks at progress, not the phase.
            if progress >= 1.0 {
                // Backend returned the final result: snap from the current position (<=90%) to 100%, cancel the "taking longer than usual" timer,
                // and clear the elapsed-long flag so the completion (still .processing with phase non-nil during the snap fill) never flashes that copy.
                longLabelTask?.cancel()
                longLabelTask = nil
                processingElapsedLong = false
                withAnimation(.easeInOut(duration: Self.snapDuration)) {
                    displayedProgress = 1.0
                }
            } else if processingStartedAt == nil {
                // First entry into the processing state: start the single 0%->90% ease. Always start from 0 (do not seed from progress),
                // ensuring the bar is one continuous ease that never anchors to phase-boundary values like 0.0/0.5.
                beginProcessingRamp()
            }
            // else: a mid-stream phase update while already ramping (e.g. 0.0->0.5) -- do not touch displayedProgress.
        default:
            // Leaving the processing state (idle/info/error/listening/transcribing-old-state): reset, preparing for the next round.
            resetProcessingTracking()
            displayedProgress = 0
        }
    }

    /// Processing-ramp start: climb the displayed value from 0 with `.easeOut` within `processingRampDuration` to the 90% ceiling and hold,
    /// and schedule a delayed task -- if still in the processing state (no final result returned) after the expected duration, flip to the "taking longer than usual" copy.
    private func beginProcessingRamp() {
        processingStartedAt = Date()
        processingElapsedLong = false
        displayedProgress = 0
        withAnimation(.easeOut(duration: Self.processingRampDuration)) {
            displayedProgress = Self.processingProgressCap
        }
        longLabelTask?.cancel()
        longLabelTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.processingRampDuration))
            guard !Task.isCancelled else { return }
            // Only flip the copy if still in the processing state (no final result returned); otherwise keep the regular copy.
            if model.state.processingPhase != nil,
               (model.state.progress ?? 1) < 1.0 {
                processingElapsedLong = true
            }
        }
    }

    /// Resets the processing-related timer and copy state, and cancels the pending delayed task.
    private func resetProcessingTracking() {
        longLabelTask?.cancel()
        longLabelTask = nil
        processingStartedAt = nil
        processingElapsedLong = false
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
    /// The fill width is bound only to the client-side displayed value `displayedProgress` (driven by `handleStateChange`) and never reads the `progress` argument:
    /// on entering the processing state it eases from 0 with ease-out within `processingRampDuration` (~3s) as a single climb to the 90% ceiling and holds,
    /// then snaps to 100% after the final result arrives -- this is one continuous ease spanning the whole run, never stopping at / anchoring to the 50% phase boundary;
    /// the wait always happens near the 90% ceiling. The `progress` argument exists only to carry state completeness and takes no part in the bar position.
    /// The foreground fill is a single white across both phases (transcribe + polish), matching the monochrome palette; the phase only selects the copy via ``statusText`` and anchors no bar value.
    private func progressBar(progress: Double, phase: RecordingState.ProcessingPhase) -> some View {
        // White in both phases (transcribe + polish) to match the monochrome palette; `phase` no longer affects color.
        let fillColor = Color.white.opacity(0.9)
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
