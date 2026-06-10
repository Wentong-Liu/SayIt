import XCTest
@testable import SayItCore

/// Locks the load-bearing behavior of the shared JSON-decode-failure logging helper on `HTTPResponseValidator`:
/// the 500-char truncation + UTF-8 fallback of `decodeFailureSnippet(data:)`, which both providers (`Anthropic` /
/// `OpenAICompatible`) feed into the identical NSLog line via `logDecodeFailure`. NSLog itself is a side effect,
/// so the assertable contract is the snippet computation.
final class HTTPResponseValidatorTests: XCTestCase {

    func testSnippetReturnsFullBodyWhenUnder500Chars() {
        let body = "{\"error\":\"oops\"}"
        let data = Data(body.utf8)
        XCTAssertEqual(HTTPResponseValidator.decodeFailureSnippet(data: data), body)
    }

    func testSnippetTruncatesAt500Chars() {
        // 600 ASCII chars -> exactly 500 expected back.
        let body = String(repeating: "a", count: 600)
        let data = Data(body.utf8)
        let snippet = HTTPResponseValidator.decodeFailureSnippet(data: data)
        XCTAssertEqual(snippet.count, 500)
        XCTAssertEqual(snippet, String(repeating: "a", count: 500))
    }

    func testSnippetIsEmptyForNonUTF8Data() {
        // An invalid UTF-8 byte sequence falls back to "" (the `?? ""` path).
        let data = Data([0xFF, 0xFE, 0xFD])
        XCTAssertEqual(HTTPResponseValidator.decodeFailureSnippet(data: data), "")
    }

    func testSnippetIsEmptyForEmptyData() {
        XCTAssertEqual(HTTPResponseValidator.decodeFailureSnippet(data: Data()), "")
    }
}
