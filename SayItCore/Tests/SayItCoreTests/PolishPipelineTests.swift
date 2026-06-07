import XCTest
@testable import SayItCore

final class PolishPipelineTests: XCTestCase {

    // MARK: - Fake LLMProvider

    /// 可控的假 Provider：用于断言 PolishPipeline 的成功/回退/空响应/抛错路径。
    /// 同时记录最近一次收到的 messages，便于验证管线确实把 PromptBuilder 的输出透传进来。
    private final class FakeLLMProvider: LLMProvider, @unchecked Sendable {
        enum Behavior {
            /// 返回固定文本。
            case returns(String)
            /// 抛出指定错误。
            case throwsError(Error)
        }

        let behavior: Behavior
        /// 最近一次 complete 收到的消息（用于断言透传）。
        private(set) var receivedMessages: [LLMMessage] = []
        /// complete 被调用的次数。
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

    // MARK: - 成功路径

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
        XCTAssertTrue(outcome.polished)
        XCTAssertFalse(outcome.usedFallback)
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
        XCTAssertTrue(outcome.polished)
        XCTAssertFalse(outcome.usedFallback)
    }

    func testSuccessForwardsPromptBuilderMessages() async {
        let provider = FakeLLMProvider(.returns("ok"))
        let pipeline = PolishPipeline()

        let raw = "在 Xcode 里写注释"
        let context = PolishContext(appName: "Xcode", bundleId: "com.apple.dt.Xcode")
        _ = await pipeline.polish(raw, context: context, style: .smart, provider: provider)

        // 管线必须用已有 PolishPromptBuilder 组装消息，原样透传给 provider。
        let expected = PolishPromptBuilder.build(rawText: raw, context: context, style: .smart)
        XCTAssertEqual(provider.receivedMessages, expected)
    }

    // MARK: - 抛错回退原文

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

        // 绝不丢用户的话：回退返回原始文本。
        XCTAssertEqual(outcome.text, raw)
        XCTAssertFalse(outcome.polished)
        XCTAssertTrue(outcome.usedFallback)
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
    }

    // MARK: - 空响应回退

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
    }

    // MARK: - 空输入

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
        XCTAssertFalse(outcome.polished)
        XCTAssertTrue(outcome.usedFallback)
        XCTAssertEqual(provider.callCount, 0, "空输入不应调用 provider")
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
        XCTAssertFalse(outcome.polished)
        XCTAssertTrue(outcome.usedFallback)
        XCTAssertEqual(provider.callCount, 0, "关闭润色时不应调用 provider")
    }

    // MARK: - PolishOutcome 构造

    func testPolishOutcomeIsEquatable() {
        let a = PolishOutcome(text: "x", polished: true, usedFallback: false)
        let b = PolishOutcome(text: "x", polished: true, usedFallback: false)
        XCTAssertEqual(a, b)
    }
}
