import Foundation

/// 云端语音转写：调用 OpenAI 兼容的音频转写 API（`POST {baseURL}/v1/audio/transcriptions`）。
///
/// 请求体为 `multipart/form-data`，含字段：
/// - `file`：把入参 `[Float]`（16kHz 单声道 PCM）经 ``WAVEncoder`` 编码的 16-bit PCM WAV。
/// - `model`：转写模型（如 `gpt-4o-mini-transcribe` / `whisper-1`），来自配置。
/// - `language`：可选 ISO 语言代码；传 `nil` 时不发该字段，让服务端自动检测。
///
/// 鉴权走 `Authorization: Bearer <apiKey>`；`baseURL` 默认 `https://api.openai.com`，
/// 可配置以支持兼容服务商。``URLSession`` 可注入以便测试（用 URLProtocol 桩，不打真实网络）。
///
/// conform 已有 ``Transcriber`` 协议，复用 ``TranscriptionResult`` / ``STTError`` /
/// ``HTTPResponseValidator``，不重复声明任何已有类型。
public struct CloudTranscriber: Transcriber {
    /// API 基地址（不含路径后缀），如 `https://api.openai.com`。尾部 `/` 会被规范化掉。
    private let baseURL: String
    /// 鉴权用 API Key；为空视作未配置 → 抛 ``STTError/notReady``。
    private let apiKey: String
    /// 转写模型标识。
    private let model: String
    private let session: URLSession

    /// 默认 API 基地址（OpenAI 官方）。
    public static let defaultBaseURL = "https://api.openai.com"

    /// 转写端点后缀（拼在规范化后的 baseURL 之后）。
    private static let transcriptionsPath = "/v1/audio/transcriptions"

    /// 单次请求超时（秒）。复用 LLM 的整体上限即可。
    private static let requestTimeout = LLMDefaults.requestTimeout

    /// - Parameters:
    ///   - baseURL: API 基地址；默认官方 `https://api.openai.com`，可改以支持兼容服务商。
    ///   - apiKey: Bearer Token。生产侧由调用方从 ``KeychainStore`` 取出后传入（本类型不读 Keychain，保持可测）。
    ///   - model: 转写模型标识（如 `gpt-4o-mini-transcribe`）。
    ///   - session: 注入的 ``URLSession``；默认 `.shared`，测试传 URLProtocol 桩。
    public init(baseURL: String = CloudTranscriber.defaultBaseURL,
                apiKey: String,
                model: String,
                session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    public func transcribe(_ audio: [Float], sampleRate: Double, language: String?) async throws -> TranscriptionResult {
        guard !audio.isEmpty else { throw STTError.emptyAudio }
        guard !apiKey.isEmpty else { throw STTError.notReady }
        guard let url = endpointURL() else {
            throw STTError.transcriptionFailed(reason: "invalid baseURL: \(baseURL)")
        }

        // 非法/越界采样率会抛 STTError.unsupportedFormat（避免 UInt32(sampleRate) 陷阱崩溃）。
        let wav = try WAVEncoder.encode(samples: audio, sampleRate: sampleRate)
        let boundary = "Boundary-\(UUID().uuidString)"
        let body = makeMultipartBody(wav: wav, boundary: boundary, language: language)

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = Self.requestTimeout
        req.setValue("multipart/form-data; boundary=\(boundary)",
                     forHTTPHeaderField: HTTPConstants.contentTypeHeader)
        req.setBearerAuthorization(apiKey)
        req.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw STTError.transcriptionFailed(reason: "network: \(error.localizedDescription)")
        }

        // 复用 provider 共享的 HTTP 校验：非 HTTP 响应 / 非 2xx 都抛 ProviderError，统一转成 STTError。
        do {
            let http = try HTTPResponseValidator.httpResponse(from: response)
            try HTTPResponseValidator.throwIfHTTPError(http, body: String(data: data, encoding: .utf8) ?? "")
        } catch let error as ProviderError {
            throw STTError.transcriptionFailed(reason: error.description)
        }

        return try parse(data)
    }

    // MARK: - 端点

    /// 把 baseURL 规范化（去尾部 `/`）后拼上转写端点后缀。
    private func endpointURL() -> URL? {
        var base = baseURL
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + Self.transcriptionsPath)
    }

    // MARK: - multipart body

    /// 构造 `multipart/form-data` 请求体：model 字段、可选 language 字段、file（WAV）字段，最后 closing boundary。
    private func makeMultipartBody(wav: Data, boundary: String, language: String?) -> Data {
        var body = Data()

        body.appendFormField(name: "model", value: model, boundary: boundary)
        if let language, !language.isEmpty {
            body.appendFormField(name: "language", value: language, boundary: boundary)
        }
        body.appendFileField(name: "file", filename: "audio.wav",
                             contentType: "audio/wav", fileData: wav, boundary: boundary)

        body.append(string: "--\(boundary)--\r\n")
        return body
    }

    // MARK: - 响应解析

    /// 转写响应体：只取 `text` 字段（其余如 task/language/duration 忽略）。
    private struct ResponseBody: Decodable {
        let text: String
    }

    /// 解析响应 JSON 的 `text` 字段为 ``TranscriptionResult``；缺字段 / 非 JSON → ``STTError/transcriptionFailed``。
    private func parse(_ data: Data) throws -> TranscriptionResult {
        guard let parsed = try? JSONDecoder().decode(ResponseBody.self, from: data) else {
            let snippet = String((String(data: data, encoding: .utf8) ?? "").prefix(200))
            throw STTError.transcriptionFailed(reason: "decode failed, body: \(snippet)")
        }
        return TranscriptionResult(text: parsed.text)
    }
}

private extension Data {
    /// 追加 UTF-8 字符串。
    mutating func append(string: String) {
        append(contentsOf: Array(string.utf8))
    }

    /// 追加一个普通文本表单字段（含前导 boundary 与 Content-Disposition）。
    mutating func appendFormField(name: String, value: String, boundary: String) {
        append(string: "--\(boundary)\r\n")
        append(string: "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        append(string: "\(value)\r\n")
    }

    /// 追加一个文件表单字段（含前导 boundary、文件名、Content-Type 与二进制数据）。
    mutating func appendFileField(name: String, filename: String, contentType: String,
                                  fileData: Data, boundary: String) {
        append(string: "--\(boundary)\r\n")
        append(string: "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        append(string: "Content-Type: \(contentType)\r\n\r\n")
        append(fileData)
        append(string: "\r\n")
    }
}
