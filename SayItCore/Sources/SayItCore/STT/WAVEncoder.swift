import Foundation

/// 把单声道 PCM 浮点样本（取值约 `[-1, 1]`）编码为内存中的 16-bit PCM WAV（含 RIFF/fmt/data 头）。
///
/// 用于云端转写：OpenAI 兼容的 `/v1/audio/transcriptions` 接收 WAV 文件上传，
/// 而录音管线产出的是 16kHz 单声道 `[Float]`，需在内存里加上正确的 WAV 头再上传。
///
/// 生成的是规范 44 字节头的 PCM WAV：
/// - RIFF chunk descriptor（"RIFF" + ChunkSize + "WAVE"）
/// - fmt subchunk（"fmt " + 16 + PCM(1) + 单声道(1) + 采样率 + 字节率 + 块对齐 + 16 bit）
/// - data subchunk（"data" + 数据大小 + 小端 16-bit 样本）
public enum WAVEncoder {
    /// 16-bit PCM：每样本 2 字节。
    private static let bytesPerSample = 2
    /// 单声道。
    private static let channelCount = 1
    /// 位深。
    private static let bitsPerSample = 16

    /// 允许的最大采样率（Hz）。上界取 `UInt32.max / 2`，保证 ByteRate
    /// （= sampleRate × 声道数 × 每样本字节数 = sampleRate × 2）也能装进 `UInt32` 不溢出。
    /// 远高于任何真实采样率，仅用于防御非法越界输入导致的 `UInt32(_:)` 陷阱崩溃。
    private static let maxSampleRate = Double(UInt32.max / UInt32(channelCount * bytesPerSample))

    /// 把浮点样本编码为完整的 WAV `Data`。
    ///
    /// - Parameters:
    ///   - samples: 单声道 PCM 样本，取值约 `[-1, 1]`；越界值会被夹紧到 `[-1, 1]`。
    ///   - sampleRate: 采样率（Hz），写入 fmt 头；按整数写入。必须在 `1...maxSampleRate` 内，
    ///     否则 `UInt32(sampleRate)` 会触发陷阱崩溃。
    /// - Returns: 含正确 RIFF/fmt/data 头的 16-bit PCM WAV 字节。
    /// - Throws: ``STTError/unsupportedFormat`` 当 `sampleRate` 不是有限正数或越界（`<= 0`、
    ///   非有限、或 `> maxSampleRate`）时。
    public static func encode(samples: [Float], sampleRate: Double) throws -> Data {
        guard sampleRate.isFinite, sampleRate >= 1, sampleRate <= maxSampleRate else {
            throw STTError.unsupportedFormat
        }

        let dataSize = samples.count * bytesPerSample
        let sr = UInt32(sampleRate)
        let byteRate = sr * UInt32(channelCount * bytesPerSample)
        let blockAlign = UInt16(channelCount * bytesPerSample)

        var data = Data(capacity: 44 + dataSize)

        // --- RIFF chunk descriptor ---
        data.append(ascii: "RIFF")
        data.appendLE(UInt32(36 + dataSize))   // ChunkSize = 36 + Subchunk2Size
        data.append(ascii: "WAVE")

        // --- fmt subchunk ---
        data.append(ascii: "fmt ")
        data.appendLE(UInt32(16))              // Subchunk1Size = 16（PCM）
        data.appendLE(UInt16(1))               // AudioFormat = 1（PCM，无压缩）
        data.appendLE(UInt16(channelCount))    // NumChannels
        data.appendLE(sr)                      // SampleRate
        data.appendLE(byteRate)                // ByteRate
        data.appendLE(blockAlign)              // BlockAlign
        data.appendLE(UInt16(bitsPerSample))   // BitsPerSample

        // --- data subchunk ---
        data.append(ascii: "data")
        data.appendLE(UInt32(dataSize))        // Subchunk2Size
        for sample in samples {
            data.appendLE(UInt16(bitPattern: int16Sample(from: sample)))
        }

        return data
    }

    /// 把 `[-1, 1]` 的浮点样本夹紧并缩放到 `Int16`。
    /// `1.0 -> Int16.max`、`-1.0 -> Int16.min`、越界值夹紧到端点。
    private static func int16Sample(from sample: Float) -> Int16 {
        let clamped = max(-1.0, min(1.0, sample))
        if clamped >= 0 {
            return Int16(clamped * Float(Int16.max))
        } else {
            // 负向用 Int16.min 的绝对值缩放，保证 -1.0 精确映射到 Int16.min。
            return Int16(-clamped * Float(Int16.min))
        }
    }
}

private extension Data {
    /// 追加 ASCII 标签（如 "RIFF"）。
    mutating func append(ascii string: String) {
        append(contentsOf: Array(string.utf8))
    }

    /// 小端追加 UInt16。
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    /// 小端追加 UInt32。
    mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
