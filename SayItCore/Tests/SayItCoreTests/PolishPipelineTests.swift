import XCTest
@testable import SayItCore

final class PolishPipelineTests: XCTestCase {

    // MARK: - Fake LLMProvider

    /// A controllable fake Provider: used to assert PolishPipeline's success/fallback/empty-response/throw paths.
    /// Also records the most recently received messages, to verify the pipeline really passes through PromptBuilder's output.
    private final class FakeLLMProvider: LLMProvider, @unchecked Sendable {
        enum Behavior {
            /// Returns fixed text.
            case returns(String)
            /// Throws the specified error.
            case throwsError(Error)
        }

        let behavior: Behavior
        /// The messages received by the most recent complete (used to assert pass-through).
        private(set) var receivedMessages: [LLMMessage] = []
        /// The number of times complete was called.
        private(set) var callCount = 0

        init(_ behavior: Behavior) {
            self.behavior = behavior
        }

        func complete(messages: [LLMMessage]) async throws -> String {
            callCount += 1
            receivedMessages = messages
            switch behavior {
            case let .returns(text):
                return text
            case let .throwsError(error):
                throw error
            }
        }
    }

    // MARK: - Success path

    func testSuccessReturnsProviderOutputPolished() async {
        let provider = FakeLLMProvider(.returns("今天天气不错。"))
        let pipeline = PolishPipeline()

        let outcome = await pipeline.polish(
            "嗯，今天天气不错",
            context: PolishContext(),
            style: .smart,
            provider: provider
        )

        XCTAssertEqual(outcome.text, "今天天气不错。")
        XCTAssertEqual(outcome.resolution, .polished)
        XCTAssertTrue(outcome.polished)
        XCTAssertFalse(outcome.usedFallback)
        XCTAssertNil(outcome.failureReason)
        XCTAssertEqual(provider.callCount, 1)
    }

    func testSuccessTrimsProviderOutput() async {
        let provider = FakeLLMProvider(.returns("\n  整理后的文本  \n"))
        let pipeline = PolishPipeline()

        let outcome = await pipeline.polish(
            "原始口述",
            context: PolishContext(),
            style: .formal,
            provider: provider
        )

        XCTAssertEqual(outcome.text, "整理后的文本")
        XCTAssertEqual(outcome.resolution, .polished)
        XCTAssertTrue(outcome.polished)
        XCTAssertFalse(outcome.usedFallback)
    }

    func testSuccessForwardsPromptBuilderMessages() async {
        let provider = FakeLLMProvider(.returns("ok"))
        let pipeline = PolishPipeline()

        let raw = "在 Xcode 里写注释"
        let context = PolishContext(appName: "Xcode", bundleId: "com.apple.dt.Xcode")
        _ = await pipeline.polish(raw, context: context, style: .smart, provider: provider)

        // The pipeline must assemble messages with the existing PolishPromptBuilder and pass them through to the provider as-is.
        let expected = PolishPromptBuilder.build(rawText: raw, context: context, style: .smart)
        XCTAssertEqual(provider.receivedMessages, expected)
    }

    // MARK: - Throw falls back to the original

    func testProviderErrorFallsBackToRawText() async {
        let provider = FakeLLMProvider(.throwsError(ProviderError.network("boom")))
        let pipeline = PolishPipeline()

        let raw = "嗯，这句话不能丢"
        let outcome = await pipeline.polish(
            raw,
            context: PolishContext(),
            style: .smart,
            provider: provider
        )

        // Never lose the user's words: the fallback returns the original text.
        XCTAssertEqual(outcome.text, raw)
        XCTAssertFalse(outcome.polished)
        XCTAssertTrue(outcome.usedFallback)
        // A throw should be judged as a "failure fallback" and carry a human-readable reason.
        if case .failedFallback = outcome.resolution {
            XCTAssertNotNil(outcome.failureReason)
        } else {
            XCTFail("a thrown error should be .failedFallback, actual: \(outcome.resolution)")
        }
    }

    func testProviderErrorInvokesFailureLogger() async {
        // A failure fallback should trigger the injected logger callback (observable).
        final class Box: @unchecked Sendable { var reasons: [String] = [] }
        let box = Box()
        let provider = FakeLLMProvider(.throwsError(ProviderError.network("boom")))
        let pipeline = PolishPipeline(logFailure: { box.reasons.append($0) })

        _ = await pipeline.polish("不能丢的口述", context: PolishContext(), style: .smart, provider: provider)

        XCTAssertEqual(box.reasons.count, 1, "a failure fallback should log the reason exactly once")
    }

    func testSkippedAndPolishedDoNotInvokeFailureLogger() async {
        // Both skip (off) and the success path should not trigger the failure logger.
        final class Box: @unchecked Sendable { var count = 0 }
        let box = Box()
        let pipeline = PolishPipeline(logFailure: { _ in box.count += 1 })

        _ = await pipeline.polish("原文", context: PolishContext(), style: .smart,
                                  provider: FakeLLMProvider(.returns("成稿")), polishEnabled: true)
        _ = await pipeline.polish("原文", context: PolishContext(), style: .smart,
                                  provider: FakeLLMProvider(.returns("x")), polishEnabled: false)

        XCTAssertEqual(box.count, 0, "success/skip should not log a failure")
    }

    func testProviderErrorFallbackTrimsRawText() async {
        let provider = FakeLLMProvider(.throwsError(ProviderError.invalidResponse))
        let pipeline = PolishPipeline()

        let outcome = await pipeline.polish(
            "   有空白边的原文   ",
            context: PolishContext(),
            style: .smart,
            provider: provider
        )

        XCTAssertEqual(outcome.text, "有空白边的原文")
        XCTAssertFalse(outcome.polished)
        XCTAssertTrue(outcome.usedFallback)
        if case .failedFallback = outcome.resolution {} else {
            XCTFail("a thrown error should be .failedFallback, actual: \(outcome.resolution)")
        }
    }

    // MARK: - Empty response falls back

    func testEmptyResponseFallsBackToRawText() async {
        let provider = FakeLLMProvider(.returns("   \n  "))
        let pipeline = PolishPipeline()

        let raw = "这句口述要保住"
        let outcome = await pipeline.polish(
            raw,
            context: PolishContext(),
            style: .smart,
            provider: provider
        )

        XCTAssertEqual(outcome.text, raw)
        XCTAssertFalse(outcome.polished)
        XCTAssertTrue(outcome.usedFallback)
        // An empty response is a "failure fallback" (the model was called but no usable result was obtained).
        if case .failedFallback = outcome.resolution {} else {
            XCTFail("an empty response should be .failedFallback, actual: \(outcome.resolution)")
        }
    }

    // MARK: - Empty input

    func testEmptyInputReturnsImmediatelyWithoutCallingProvider() async {
        let provider = FakeLLMProvider(.returns("不应被使用"))
        let pipeline = PolishPipeline()

        let outcome = await pipeline.polish(
            "",
            context: PolishContext(),
            style: .smart,
            provider: provider
        )

        XCTAssertEqual(outcome.text, "")
        XCTAssertEqual(outcome.resolution, .skipped(.emptyInput))
        XCTAssertFalse(outcome.polished)
        XCTAssertTrue(outcome.usedFallback)
        XCTAssertEqual(provider.callCount, 0, "empty input should not call the provider")
    }

    func testWhitespaceOnlyInputReturnsTrimmedWithoutCallingProvider() async {
        let provider = FakeLLMProvider(.returns("不应被使用"))
        let pipeline = PolishPipeline()

        let outcome = await pipeline.polish(
            "   \n\t  ",
            context: PolishContext(),
            style: .smart,
            provider: provider
        )

        XCTAssertEqual(outcome.text, "")
        XCTAssertEqual(outcome.resolution, .skipped(.emptyInput))
        XCTAssertFalse(outcome.polished)
        XCTAssertTrue(outcome.usedFallback)
        XCTAssertEqual(provider.callCount, 0)
    }

    // MARK: - polishEnabled = false

    func testPolishDisabledReturnsRawWithoutCallingProvider() async {
        let provider = FakeLLMProvider(.returns("不应被使用"))
        let pipeline = PolishPipeline()

        let raw = "保持原文不动"
        let outcome = await pipeline.polish(
            raw,
            context: PolishContext(),
            style: .smart,
            provider: provider,
            polishEnabled: false
        )

        XCTAssertEqual(outcome.text, raw)
        XCTAssertEqual(outcome.resolution, .skipped(.disabled))
        XCTAssertFalse(outcome.polished)
        XCTAssertTrue(outcome.usedFallback)
        XCTAssertEqual(provider.callCount, 0, "the provider should not be called when polishing is disabled")
    }

    // MARK: - PolishOutcome construction

    func testPolishOutcomeIsEquatable() {
        let a = PolishOutcome(text: "x", resolution: .polished)
        let b = PolishOutcome(text: "x", resolution: .polished)
        XCTAssertEqual(a, b)
    }

    func testPolishOutcomeDerivedFlags() {
        XCTAssertTrue(PolishOutcome(text: "x", resolution: .polished).polished)
        XCTAssertFalse(PolishOutcome(text: "x", resolution: .polished).usedFallback)
        XCTAssertTrue(PolishOutcome(text: "x", resolution: .skipped(.disabled)).usedFallback)
        XCTAssertEqual(PolishOutcome(text: "x", resolution: .failedFallback(reason: "r")).failureReason, "r")
    }
}
