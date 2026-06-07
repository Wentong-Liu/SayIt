import XCTest
@testable import SayItCore

/// WAVEncoder sample-rate validation unit test: focuses on the early-return behavior for invalid/out-of-range sample rates, avoiding the `UInt32(sampleRate)` trap crash.
/// (WAV header byte-level correctness is already covered in CloudTranscriberTests, not repeated here.)
final class WAVEncoderTests: XCTestCase {

    func testValidSampleRateEncodes() throws {
        let wav = try WAVEncoder.encode(samples: [0.0, 0.5, -0.5], sampleRate: 16_000)
        // 44-byte header + 3 samples x 2 bytes.
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
        // A value exceeding UInt32.max (about 4.29e9), where UInt32(sampleRate) would trap-crash.
        assertUnsupportedFormat(sampleRate: Double(UInt32.max) + 1)
    }

    func testHugeSampleRateThatWouldOverflowByteRateThrows() {
        // Between UInt32.max/2 and UInt32.max: sr itself fits into UInt32, but ByteRate = sr*2 would overflow,
        // so it should also be rejected.
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
