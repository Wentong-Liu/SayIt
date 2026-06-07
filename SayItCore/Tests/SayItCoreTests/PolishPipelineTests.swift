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
        // 抛错应判定为「失败回退」并携带可读原因。
        if case .failedFallback = outcome.resolution {
            XCTAssertNotNil(outcome.failureReason)
        } else {
            XCTFail("抛错应为 .failedFallback，实际: \(outcome.resolution)")
        }
    }

    func testProviderErrorInvokesFailureLogger() async {
        // 失败回退应触发注入的 logger 回调（可观测）。
        final class Box: @unchecked Sendable { var reasons: [String] = [] }
        let box = Box()
        let provider = FakeLLMProvider(.throwsError(ProviderError.network("boom")))
        let pipeline = PolishPipeline(logFailure: { box.reasons.append($0) })

        _ = await pipeline.polish("不能丢的口述", context: PolishContext(), style: .smart, provider: provider)

        XCTAssertEqual(box.reasons.count, 1, "失败回退应记录一次原因")
    }

    func testSkippedAndPolishedDoNotInvokeFailureLogger() async {
        // 跳过（关闭）与成功路径都不应触发失败 logger。
        final class Box: @unchecked Sendable { var count = 0 }
        let box = Box()
        let pipeline = PolishPipeline(logFailure: { _ in box.count += 1 })

        _ = await pipeline.polish("原文", context: PolishContext(), style: .smart,
                                  provider: FakeLLMProvider(.returns("成稿")), polishEnabled: true)
        _ = await pipeline.polish("原文", context: PolishContext(), style: .smart,
                                  provider: FakeLLMProvider(.returns("x")), polishEnabled: false)

        XCTAssertEqual(box.count, 0, "成功/跳过不应记录失败")
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
            XCTFail("抛错应为 .failedFallback，实际: \(outcome.resolution)")
        }
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
        // 空响应属于「失败回退」（调用了模型但没拿到可用结果）。
        if case .failedFallback = outcome.resolution {} else {
            XCTFail("空响应应为 .failedFallback，实际: \(outcome.resolution)")
        }
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
        XCTAssertEqual(outcome.resolution, .skipped(.emptyInput))
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
        XCTAssertEqual(provider.callCount, 0, "关闭润色时不应调用 provider")
    }

    // MARK: - PolishOutcome 构造

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
