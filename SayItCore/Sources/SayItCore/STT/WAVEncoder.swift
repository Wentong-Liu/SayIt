import Foundation

/// Encodes mono PCM float samples (roughly in `[-1, 1]`) into an in-memory 16-bit PCM WAV (with RIFF/fmt/data headers).
///
/// Used for cloud transcription: the OpenAI-compatible `/v1/audio/transcriptions` accepts a WAV file upload,
/// while the recording pipeline produces 16kHz mono `[Float]`, so a correct WAV header must be added in memory before upload.
///
/// It produces a canonical 44-byte-header PCM WAV:
/// - RIFF chunk descriptor ("RIFF" + ChunkSize + "WAVE")
/// - fmt subchunk ("fmt " + 16 + PCM(1) + mono(1) + sample rate + byte rate + block align + 16 bit)
/// - data subchunk ("data" + data size + little-endian 16-bit samples)
public enum WAVEncoder {
    /// 16-bit PCM: 2 bytes per sample.
    private static let bytesPerSample = 2
    /// Mono.
    private static let channelCount = 1
    /// Bit depth.
    private static let bitsPerSample = 16

    /// Maximum allowed sample rate (Hz). The upper bound is `UInt32.max / 2`, guaranteeing the ByteRate
    /// (= sampleRate * channelCount * bytesPerSample = sampleRate * 2) also fits into `UInt32` without overflow.
    /// Far above any real sample rate; used only to defend against the `UInt32(_:)` trap crash from invalid out-of-range input.
    private static let maxSampleRate = Double(UInt32.max / UInt32(channelCount * bytesPerSample))

    /// Encodes float samples into a complete WAV `Data`.
    ///
    /// - Parameters:
    ///   - samples: mono PCM samples, roughly in `[-1, 1]`; out-of-range values are clamped to `[-1, 1]`.
    ///   - sampleRate: sample rate (Hz), written into the fmt header; written as an integer. Must be within `1...maxSampleRate`,
    ///     otherwise `UInt32(sampleRate)` triggers a trap crash.
    /// - Returns: 16-bit PCM WAV bytes with correct RIFF/fmt/data headers.
    /// - Throws: ``STTError/unsupportedFormat`` when `sampleRate` is not a finite positive number or is out of range (`<= 0`,
    ///   non-finite, or `> maxSampleRate`).
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
        data.appendLE(UInt32(16))              // Subchunk1Size = 16 (PCM)
        data.appendLE(UInt16(1))               // AudioFormat = 1 (PCM, uncompressed)
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

    /// Clamps `[-1, 1]` float samples and scales them to `Int16`.
    /// `1.0 -> Int16.max`, `-1.0 -> Int16.min`, out-of-range values clamped to the endpoints.
    private static func int16Sample(from sample: Float) -> Int16 {
        let clamped = max(-1.0, min(1.0, sample))
        if clamped >= 0 {
            return Int16(clamped * Float(Int16.max))
        } else {
            // Scale the negative side by the absolute value of Int16.min, guaranteeing -1.0 maps exactly to Int16.min.
            return Int16(-clamped * Float(Int16.min))
        }
    }
}

private extension Data {
    /// Appends an ASCII tag (e.g. "RIFF").
    mutating func append(ascii string: String) {
        append(contentsOf: Array(string.utf8))
    }

    /// Appends a UInt16 in little-endian.
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    /// Appends a UInt32 in little-endian.
    mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
