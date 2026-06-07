import Foundation

/// 一次语音转写的结果。
///
/// `text` 为完整转写文本；`segments` 与 `duration` 为可选元数据，
/// 不同后端（本地 WhisperKit / 云端）可按能力填充，未提供时分别为空数组与 `nil`。
public struct TranscriptionResult: Equatable, Sendable {
    /// 转写出的单个时间分段。
    public struct Segment: Equatable, Sendable {
        /// 该分段的文本。
        public let text: String
        /// 起始时间（秒，相对于音频开头）。
        public let start: Double
        /// 结束时间（秒，相对于音频开头）。
        public let end: Double

        public init(text: String, start: Double, end: Double) {
            self.text = text
            self.start = start
            self.end = end
        }
    }

    /// 完整转写文本。
    public let text: String
    /// 分段信息；后端不支持分段时为空数组。
    public let segments: [Segment]
    /// 音频时长（秒）；后端未提供时为 `nil`。
    public let duration: Double?

    public init(text: String, segments: [Segment] = [], duration: Double? = nil) {
        self.text = text
        self.segments = segments
        self.duration = duration
    }
}
