import XCTest
@testable import SayItCore

/// WAVEncoder 采样率校验单测：聚焦非法/越界采样率的早退行为，避免 `UInt32(sampleRate)` 陷阱崩溃。
/// （WAV 头字节级正确性已在 CloudTranscriberTests 覆盖，这里不重复。）
final class WAVEncoderTests: XCTestCase {

    func testValidSampleRateEncodes() throws {
        let wav = try WAVEncoder.encode(samples: [0.0, 0.5, -0.5], sampleRate: 16_000)
        // 44 字节头 + 3 样本 × 2 字节。
        XCTAssertEqual(wav.count, 44 + 3 * 2)
    }

    func testZeroSampleRateThrowsUnsupportedFormat() {
        assertUnsupportedFormat(sampleRate: 0)
    }

    func testNegativeSampleRateThrowsUnsupportedFormat() {
        assertUnsupportedFormat(sampleRate: -16_000)
    }

    func testFractionalBelowOneSampleRateThrowsUnsupportedFormat() {
        assertUnsupportedFormat(sampleRate: 0.5)
    }

    func testNaNSampleRateThrowsUnsupportedFormat() {
        assertUnsupportedFormat(sampleRate: .nan)
    }

    func testInfiniteSampleRateThrowsUnsupportedFormat() {
        assertUnsupportedFormat(sampleRate: .infinity)
    }

    func testOutOfRangeSampleRateThrowsUnsupportedFormat() {
        // 超过 UInt32.max（约 4.29e9），且 UInt32(sampleRate) 会陷阱崩溃的取值。
        assertUnsupportedFormat(sampleRate: Double(UInt32.max) + 1)
    }

    func testHugeSampleRateThatWouldOverflowByteRateThrows() {
        // 介于 UInt32.max/2 与 UInt32.max 之间：sr 本身能装进 UInt32，但 ByteRate = sr×2 会溢出，
        // 因此也应被拒绝。
        assertUnsupportedFormat(sampleRate: Double(UInt32.max) - 10)
    }

    // MARK: - Helpers

    private func assertUnsupportedFormat(sampleRate: Double,
                                         file: StaticString = #filePath, line: UInt = #line) {
        do {
            _ = try WAVEncoder.encode(samples: [0.0], sampleRate: sampleRate)
            XCTFail("expected STTError.unsupportedFormat for sampleRate=\(sampleRate)", file: file, line: line)
        } catch let error as STTError {
            XCTAssertEqual(error, .unsupportedFormat, file: file, line: line)
        } catch {
            XCTFail("unexpected error type: \(error)", file: file, line: line)
        }
    }
}
