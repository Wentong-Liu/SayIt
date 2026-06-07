import Foundation

/// 两个 provider 共享的 HTTP 响应校验：把"取 HTTPURLResponse + 状态码区间判定 + 映射 ProviderError"
/// 抽到一处，保证两边行为完全一致。
public enum HTTPResponseValidator {
    /// 视作成功的状态码区间。
    public static let successRange = 200..<300

    /// 把 URLResponse 转成 HTTPURLResponse；不是 HTTP 响应则抛 `.invalidResponse`。
    static func httpResponse(from response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        return http
    }

    /// 非 2xx 状态码即抛 `.httpError(status:body:)`，否则正常返回。
    /// `body` 由调用方按各自的数据来源（已读 Data / 流式剩余行）提供。
    static func throwIfHTTPError(_ http: HTTPURLResponse, body: @autoclosure () -> String) throws {
        guard successRange.contains(http.statusCode) else {
            throw ProviderError.httpError(status: http.statusCode, body: body())
        }
    }
}
