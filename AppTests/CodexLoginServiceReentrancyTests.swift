import XCTest
@testable import SayIt
@testable import SayItCore

/// Regression guard for the re-entrant ChatGPT login token-exchange race.
///
/// Root cause: `login()` is documented re-entrant — a second `login()` wraps up the prior flow
/// (fires its completion with `.cancelled`) and installs a NEW completion. The token-exchange Task
/// launched by the first flow captured `self` strongly and called `finish(.success)` directly when
/// its network round-trip resolved, WITHOUT checking the flow was still current. So if a second
/// `login()` started while the first flow's exchange was still in flight, the orphaned round-1 Task
/// would fire the round-2 completion with round-1's tokens (a cross-flow result mix-up).
///
/// The fix stamps each login with a monotonically increasing `flowID`; the exchange captures that id
/// before its await and routes its result through the guarded delivery, which drops any result whose
/// flow is no longer current. These tests drive that contract through the `...ForTesting` seams so the
/// race is reproduced deterministically, with no loopback listener / browser / network round-trip.
@MainActor
final class CodexLoginServiceReentrancyTests: XCTestCase {

    /// Sample tokens that stand in for "round-1's tokens" — the ones that must never leak into round 2.
    private func makeTokens(access: String) -> OAuthTokens {
        OAuthTokens(accessToken: access, refreshToken: "r", idToken: "", accountId: "",
                    expiresAt: Date().addingTimeInterval(3600))
    }

    /// A late success from a superseded flow must NOT fire the current flow's completion. This is the
    /// exact cross-flow mix-up: before the fix, round-1's late `finish(.success)` fired round-2's
    /// completion with round-1's tokens.
    func testLateExchangeSuccessFromSupersededFlowDoesNotFireNewCompletion() {
        let service = CodexLoginService()

        var flowAResult: Result<OAuthTokens, Error>?
        var flowAFireCount = 0
        let flowA = service.beginFlowForTesting { flowAFireCount += 1; flowAResult = $0 }

        var flowBFireCount = 0
        var flowBResult: Result<OAuthTokens, Error>?
        let flowB = service.beginFlowForTesting { flowBFireCount += 1; flowBResult = $0 }

        XCTAssertNotEqual(flowA, flowB, "starting a second flow must stamp a fresh flow identity")
        XCTAssertEqual(flowAFireCount, 1, "starting flow B should wrap up flow A exactly once")
        if case .failure(let err)? = flowAResult, case CodexLoginService.LoginError.cancelled = err {
            // expected: flow A is wrapped up with .cancelled when flow B starts
        } else {
            XCTFail("flow A should have been finished with .cancelled, got \(String(describing: flowAResult))")
        }

        // Flow A's orphaned, in-flight exchange resolves LATE with round-1 tokens.
        service.deliverExchangeResultForTesting(flow: flowA, .success(makeTokens(access: "round-1-token")))

        XCTAssertEqual(flowBFireCount, 0,
                       "a superseded flow's late success must not fire the new flow's completion (cross-flow mix-up)")
        XCTAssertNil(flowBResult, "flow B's completion must not receive flow A's tokens")
        XCTAssertEqual(flowAFireCount, 1, "the late delivery must not re-fire flow A's already-consumed completion")
    }

    /// A late failure from a superseded flow must likewise be dropped, not surfaced to the new flow.
    func testLateExchangeFailureFromSupersededFlowIsDropped() {
        let service = CodexLoginService()

        let flowA = service.beginFlowForTesting { _ in }

        var flowBFireCount = 0
        _ = service.beginFlowForTesting { _ in flowBFireCount += 1 }

        service.deliverExchangeResultForTesting(
            flow: flowA, .failure(CodexLoginService.LoginError.exchangeFailed("HTTP 500")))

        XCTAssertEqual(flowBFireCount, 0,
                       "a superseded flow's late failure must not fire the current flow's completion")
    }

    /// The normal single-login path is unchanged: a result delivered for the CURRENT flow fires its completion.
    func testCurrentFlowExchangeSuccessFiresItsCompletion() {
        let service = CodexLoginService()

        var result: Result<OAuthTokens, Error>?
        var fireCount = 0
        let flow = service.beginFlowForTesting { fireCount += 1; result = $0 }

        service.deliverExchangeResultForTesting(flow: flow, .success(makeTokens(access: "current-token")))

        XCTAssertEqual(fireCount, 1, "a result for the current flow must fire its completion exactly once")
        if case .success(let tokens)? = result {
            XCTAssertEqual(tokens.accessToken, "current-token", "the current flow should receive its own tokens")
        } else {
            XCTFail("expected success for the current flow, got \(String(describing: result))")
        }

        // Delivering succeeded already cleared the completion via finish(); a re-delivery for the same
        // (still-current) id must be a safe no-op rather than re-firing.
        service.deliverExchangeResultForTesting(flow: flow, .success(makeTokens(access: "duplicate")))
        XCTAssertEqual(fireCount, 1, "a duplicate late delivery must not re-fire the completion")
    }
}
