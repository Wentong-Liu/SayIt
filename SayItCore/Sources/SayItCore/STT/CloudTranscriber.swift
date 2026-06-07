import Foundation

/// Cloud speech transcription: calls the OpenAI-compatible audio transcription API (`POST {baseURL}/v1/audio/transcriptions`).
///
/// The request body is `multipart/form-data`, containing the fields:
/// - `file`: the input `[Float]` (16kHz mono PCM) encoded by ``WAVEncoder`` into 16-bit PCM WAV.
/// - `model`: the transcription model (e.g. `gpt-4o-mini-transcribe` / `whisper-1`), from config.
/// - `language`: optional ISO language code; when `nil` the field is omitted, letting the server auto-detect.
///
/// Auth goes through `Authorization: Bearer <apiKey>`; `baseURL` defaults to `https://api.openai.com`,
/// and is configurable to support compatible providers. ``URLSession`` is injectable for testing (URLProtocol stub, no real network).
///
/// Conforms to the existing ``Transcriber`` protocol and reuses ``TranscriptionResult`` / ``STTError`` /
/// ``HTTPResponseValidator``, without redeclaring any existing type.
public struct CloudTranscriber: Transcriber {
    /// API base address (without path suffix), e.g. `https://api.openai.com`. A trailing `/` is normalized away.
    private let baseURL: String
    /// API Key for auth; empty is treated as unconfigured -> throws ``STTError/notReady``.
    private let apiKey: String
    /// Transcription model identifier.
    private let model: String
    private let session: URLSession

    /// Default API base address (OpenAI official).
    public static let defaultBaseURL = "https://api.openai.com"

    /// Transcription endpoint suffix (appended after the normalized baseURL).
    private static let transcriptionsPath = "/v1/audio/transcriptions"

    /// Timeout (seconds) for a single request. Reusing the LLM's overall ceiling is fine.
    private static let requestTimeout = LLMDefaults.requestTimeout

    /// - Parameters:
    ///   - baseURL: API base address; defaults to the official `https://api.openai.com`, changeable to support compatible providers.
    ///   - apiKey: Bearer Token. On the production side the caller retrieves it from ``KeychainStore`` and passes it in (this type never reads the Keychain, staying testable).
    ///   - model: transcription model identifier (e.g. `gpt-4o-mini-transcribe`).
    ///   - session: injected ``URLSession``; defaults to `.shared`, tests pass a URLProtocol stub.
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

        // An invalid/out-of-range sample rate throws STTError.unsupportedFormat (avoiding the UInt32(sampleRate) trap crash).
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

        // Reuse the provider-shared HTTP validation: non-HTTP responses / non-2xx both throw ProviderError, uniformly converted to STTError.
        do {
            let http = try HTTPResponseValidator.httpResponse(from: response)
            try HTTPResponseValidator.throwIfHTTPError(http, body: String(data: data, encoding: .utf8) ?? "")
        } catch let error as ProviderError {
            throw STTError.transcriptionFailed(reason: error.description)
        }

        return try parse(data)
    }

    // MARK: - Endpoint

    /// Normalizes baseURL (drops trailing `/`) then appends the transcription endpoint suffix.
    private func endpointURL() -> URL? {
        var base = baseURL
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + Self.transcriptionsPath)
    }

    // MARK: - multipart body

    /// Builds the `multipart/form-data` request body: model field, optional language field, file (WAV) field, then the closing boundary.
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

    // MARK: - Response parsing

    /// Transcription response body: takes only the `text` field (others like task/language/duration are ignored).
    private struct ResponseBody: Decodable {
        let text: String
    }

    /// Parses the response JSON's `text` field into ``TranscriptionResult``; missing field / non-JSON -> ``STTError/transcriptionFailed``.
    private func parse(_ data: Data) throws -> TranscriptionResult {
        guard let parsed = try? JSONDecoder().decode(ResponseBody.self, from: data) else {
            let snippet = String((String(data: data, encoding: .utf8) ?? "").prefix(200))
            throw STTError.transcriptionFailed(reason: "decode failed, body: \(snippet)")
        }
        return TranscriptionResult(text: parsed.text)
    }
}

private extension Data {
    /// Appends a UTF-8 string.
    mutating func append(string: String) {
        append(contentsOf: Array(string.utf8))
    }

    /// Appends a plain text form field (including the leading boundary and Content-Disposition).
    mutating func appendFormField(name: String, value: String, boundary: String) {
        append(string: "--\(boundary)\r\n")
        append(string: "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        append(string: "\(value)\r\n")
    }

    /// Appends a file form field (including the leading boundary, file name, Content-Type and binary data).
    mutating func appendFileField(name: String, filename: String, contentType: String,
                                  fileData: Data, boundary: String) {
        append(string: "--\(boundary)\r\n")
        append(string: "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        append(string: "Content-Type: \(contentType)\r\n\r\n")
        append(fileData)
        append(string: "\r\n")
    }
}
