import XCTest
@testable import SayItCore

/// Tests for ``LearnedTermExtractor`` (learn-from-edits Part B v2): with a fake ``LLMProvider`` returning canned replies,
/// assert robust JSON parsing of the {heard, corrected} pair, the null-pair -> nil, code-fenced JSON, garbage -> nil, and
/// provider throw -> nil. The single-term HARD guard is asserted in the coordinator tests (it lives there so it applies
/// regardless of extractor).
final class LearnedTermExtractorTests: XCTestCase {

    /// A controllable fake provider: returns canned text or throws, and records the messages it received.
    private final class FakeProvider: LLMProvider, @unchecked Sendable {
        enum Behavior {
            case returns(String)
            case throwsError(Error)
        }
        let behavior: Behavior
        private(set) var callCount = 0
        private(set) var receivedMessages: [LLMMessage] = []

        init(_ behavior: Behavior) { self.behavior = behavior }

        func complete(messages: [LLMMessage]) async throws -> String {
            callCount += 1
            receivedMessages = messages
            switch behavior {
            case let .returns(text): return text
            case let .throwsError(error): throw error
            }
        }
    }

    private struct DummyError: Error {}

    // MARK: - Well-formed JSON

    func testWellFormedJSONIsParsed() async {
        let provider = FakeProvider(.returns(#"{"heard": "use effect", "corrected": "useEffect"}"#))
        let extractor = LearnedTermExtractor(provider: provider)
        let term = await extractor.extract(injected: "use effect", final: "useEffect")
        XCTAssertEqual(term, LearnedTerm(heard: "use effect", corrected: "useEffect"))
        XCTAssertEqual(provider.callCount, 1)
    }

    func testChineseEmbeddedEnglishIsParsed() async {
        let provider = FakeProvider(.returns(#"{"heard": "Type+", "corrected": "Typeless"}"#))
        let extractor = LearnedTermExtractor(provider: provider)
        let term = await extractor.extract(injected: "我之前用过Type+和闪电书。", final: "我之前用过Typeless和闪电书。")
        XCTAssertEqual(term, LearnedTerm(heard: "Type+", corrected: "Typeless"))
    }

    // MARK: - Null pair

    func testNullPairYieldsNil() async {
        let provider = FakeProvider(.returns(#"{"heard": null, "corrected": null}"#))
        let extractor = LearnedTermExtractor(provider: provider)
        let term = await extractor.extract(injected: "a", final: "b")
        XCTAssertNil(term, "a null pair means the edit is not a single-term correction -> nil")
    }

    func testPartialNullPairYieldsNil() async {
        let provider = FakeProvider(.returns(#"{"heard": "x", "corrected": null}"#))
        let extractor = LearnedTermExtractor(provider: provider)
        let term = await extractor.extract(injected: "a", final: "b")
        XCTAssertNil(term, "a missing corrected -> nil")
    }

    // MARK: - Code-fenced JSON

    func testCodeFencedJSONIsParsed() async {
        let reply = """
        Here is the result:
        ```json
        {"heard": "jon", "corrected": "John"}
        ```
        """
        let provider = FakeProvider(.returns(reply))
        let extractor = LearnedTermExtractor(provider: provider)
        let term = await extractor.extract(injected: "I met jon", final: "I met John")
        XCTAssertEqual(term, LearnedTerm(heard: "jon", corrected: "John"))
    }

    func testJSONWithSurroundingProseIsParsed() async {
        let provider = FakeProvider(.returns(#"The corrected term is {"heard": "sequoia", "corrected": "Sequoia"} as shown."#))
        let extractor = LearnedTermExtractor(provider: provider)
        let term = await extractor.extract(injected: "sequoia", final: "Sequoia")
        XCTAssertEqual(term, LearnedTerm(heard: "sequoia", corrected: "Sequoia"))
    }

    // MARK: - Garbage / failure

    func testGarbageReplyYieldsNil() async {
        let provider = FakeProvider(.returns("I'm not sure what you mean."))
        let extractor = LearnedTermExtractor(provider: provider)
        let term = await extractor.extract(injected: "a", final: "b")
        XCTAssertNil(term, "a reply with no JSON object -> nil")
    }

    func testMalformedJSONYieldsNil() async {
        let provider = FakeProvider(.returns(#"{"heard": "x", "corrected":}"#))
        let extractor = LearnedTermExtractor(provider: provider)
        let term = await extractor.extract(injected: "a", final: "b")
        XCTAssertNil(term, "malformed JSON -> nil")
    }

    func testProviderThrowYieldsNil() async {
        let provider = FakeProvider(.throwsError(DummyError()))
        let extractor = LearnedTermExtractor(provider: provider)
        let term = await extractor.extract(injected: "a", final: "b")
        XCTAssertNil(term, "a provider throw -> nil (drop silently)")
    }

    func testEmptyStringFieldsYieldNil() async {
        let provider = FakeProvider(.returns(#"{"heard": "", "corrected": "  "}"#))
        let extractor = LearnedTermExtractor(provider: provider)
        let term = await extractor.extract(injected: "a", final: "b")
        XCTAssertNil(term, "empty / whitespace-only fields -> nil")
    }

    // MARK: - Prompt shape

    func testPromptContainsBothTexts() async {
        let provider = FakeProvider(.returns(#"{"heard": null, "corrected": null}"#))
        let extractor = LearnedTermExtractor(provider: provider)
        _ = await extractor.extract(injected: "ORIG_TEXT", final: "FINAL_TEXT")
        let combined = provider.receivedMessages.map(\.content).joined(separator: "\n")
        XCTAssertTrue(combined.contains("ORIG_TEXT"), "the prompt should carry the injected text")
        XCTAssertTrue(combined.contains("FINAL_TEXT"), "the prompt should carry the final text")
        XCTAssertTrue(provider.receivedMessages.contains { $0.role == .system }, "should include a system prompt")
    }

    /// The system prompt must tell the model the ORIGINAL is speech-recognizer output so its errors are PHONETIC (the core
    /// of the fix): without that framing the model returns a null pair on sound-alike mishears.
    func testSystemPromptMentionsSpeechAndPhonetic() async {
        let provider = FakeProvider(.returns(#"{"heard": null, "corrected": null}"#))
        let extractor = LearnedTermExtractor(provider: provider)
        _ = await extractor.extract(injected: "a", final: "b")
        let system = provider.receivedMessages.first { $0.role == .system }?.content ?? ""
        XCTAssertTrue(system.uppercased().contains("PHONETIC"), "the system prompt should name PHONETIC errors")
        XCTAssertTrue(system.lowercased().contains("speech"), "the system prompt should say the ORIGINAL is speech output")
    }
}
