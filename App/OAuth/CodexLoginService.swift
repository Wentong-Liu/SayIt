import AppKit
import Network
import SayItCore

/// ChatGPT login: starts a ChatGPTOAuth.callbackHost:callbackPort loopback service to receive the OAuth callback, opens the browser to authorize, exchanges the token and stores it in the Keychain; refreshes on demand.
@MainActor
final class CodexLoginService {
    static let shared = CodexLoginService()

    /// Login timeout (seconds): if the user opens the browser but never completes authorization, it automatically wraps up when time is up, releasing port callbackPort.
    private static let loginTimeout: TimeInterval = 300

    private var listener: NWListener?
    private var pkce: PKCE?
    private var state: String = ""
    private var completion: ((Result<OAuthTokens, Error>) -> Void)?
    private var timeoutTask: Task<Void, Never>?
    /// Monotonically increasing identity for the current login flow. login() is re-entrant: starting a
    /// new flow wraps up the prior one and bumps this id. The token-exchange Task captures the id at the
    /// start of its async round-trip and re-checks it before delivering, so an orphaned prior-flow exchange
    /// that resolves late cannot fire the new flow's completion with stale cross-flow tokens.
    private var flowID: UInt64 = 0

    enum LoginError: Error, CustomStringConvertible {
        case serverFailed, stateMismatch, noCode, exchangeFailed(String), cancelled, timedOut
        // These descriptions surface to the user as the polish-pane status message (via
        // SettingsViewModel.loginWithChatGPT's failure path), so they must follow the selected UI
        // language, not the system locale — same root cause / fix pattern as PR #67.
        var description: String {
            switch self {
            case .serverFailed:
                return uiLanguageLocalized(format: "login.serverFailed %lld",
                                           defaultValue: "Local loopback server failed to start (port %lld may be in use)",
                                           Int(ChatGPTOAuth.callbackPort))
            case .stateMismatch:
                return uiLanguageLocalized("login.stateMismatch", defaultValue: "State verification failed")
            case .noCode:
                return uiLanguageLocalized("login.noCode", defaultValue: "No authorization code in callback")
            case .exchangeFailed(let m):
                return uiLanguageLocalized(format: "login.exchangeFailed %@",
                                           defaultValue: "Token exchange failed: %@", m)
            case .cancelled:
                return uiLanguageLocalized("login.cancelled", defaultValue: "Login cancelled")
            case .timedOut:
                return uiLanguageLocalized("login.timedOut", defaultValue: "Login timed out, please try again")
            }
        }
    }

    /// Starts the login flow: start service -> open browser -> wait for callback -> exchange token.
    /// Re-entrancy protection: if there is already a login in progress, wrap up the old flow first (cancel listener + report cancelled to the old completion), guaranteeing only one session at a time.
    func login(completion: @escaping (Result<OAuthTokens, Error>) -> Void) {
        beginFlow(installing: completion)
        let pkce = PKCE.generate()
        self.pkce = pkce
        self.state = UUID().uuidString

        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: ChatGPTOAuth.callbackPort)!)
            l.newConnectionHandler = { [weak self] conn in
                Task { @MainActor [weak self] in self?.handle(conn) }
            }
            l.stateUpdateHandler = { [weak self] st in
                if case .failed = st {
                    Task { @MainActor [weak self] in self?.finish(.failure(LoginError.serverFailed)) }
                }
            }
            l.start(queue: .main)
            self.listener = l
        } catch {
            finish(.failure(LoginError.serverFailed)); return
        }

        // Timeout wrap-up: if still listening when time is up (the user did not complete authorization), automatically finish to release the port and trigger the completion.
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.loginTimeout))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.listener != nil else { return }
                self.finish(.failure(LoginError.timedOut))
            }
        }

        NSWorkspace.shared.open(ChatGPTOAuth.authorizeURL(pkce: pkce, state: state))
    }

    /// Wraps up any prior flow (cancel listener + fire its completion with .cancelled + stop its timeout),
    /// stamps a fresh `flowID`, and installs the new completion. Centralizes the re-entrant flow-identity
    /// transition so the token-exchange guard (deliverExchangeResult) and the regression test agree on it.
    private func beginFlow(installing completion: @escaping (Result<OAuthTokens, Error>) -> Void) {
        finish(.failure(LoginError.cancelled))  // Clean up the previous round (if any): cancel the old listener, trigger the old completion, stop the old timeout
        flowID &+= 1  // Stamp a fresh flow identity so a prior flow's in-flight exchange cannot deliver into this one.
        self.completion = completion
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .main)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            let reqText = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            // Of the form "GET /auth/callback?code=...&state=... HTTP/1.1"
            let firstLine = reqText.split(separator: "\r\n").first.map(String.init) ?? ""
            let path = firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            // Shown in the user's browser when the OAuth callback lands — follow the selected UI language.
            let doneText = uiLanguageLocalized("login.browserDone",
                                               defaultValue: "SayIt: Login complete. You can close this page and return to the app.")
            let html = "<html><body><h3>\(doneText)</h3></body></html>"
            let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
            Task { @MainActor [weak self] in self?.onCallback(path: path) }
        }
    }

    private func onCallback(path: String) {
        guard let comps = URLComponents(string: "http://\(ChatGPTOAuth.callbackHost):\(ChatGPTOAuth.callbackPort)\(path)"),
              comps.path == "/auth/callback" else { return }
        let items = comps.queryItems ?? []
        let code = items.first(where: { $0.name == "code" })?.value
        let st = items.first(where: { $0.name == "state" })?.value
        guard st == state else { finish(.failure(LoginError.stateMismatch)); return }
        guard let code, let verifier = pkce?.verifier else { finish(.failure(LoginError.noCode)); return }

        // Capture the current flow identity before the async round-trip. login() is re-entrant, so a
        // second login() may start (and wrap up this one with .cancelled) while this exchange is still
        // in flight; deliverExchangeResult drops a late result whose flow is no longer current.
        let flow = flowID
        Task {
            do {
                let (data, resp) = try await URLSession.shared.data(
                    for: ChatGPTOAuth.tokenExchangeRequest(code: code, verifier: verifier))
                let http = resp as? HTTPURLResponse
                guard let http, HTTPResponseValidator.successRange.contains(http.statusCode) else {
                    // Token exchange non-2xx: the diagnostic string contains only the status code, never the response body (to avoid token leaks).
                    let statusCode = http?.statusCode ?? -1
                    self.deliverExchangeResult(flow: flow, .failure(LoginError.exchangeFailed("HTTP \(statusCode)"))); return
                }
                let tokens = try ChatGPTOAuth.parseTokenResponse(data)
                // Do not report success on save failure: if it cannot be written to the keychain, report failure honestly.
                if KeychainStore.saveChatGPTTokens(tokens) {
                    self.deliverExchangeResult(flow: flow, .success(tokens))
                } else {
                    self.deliverExchangeResult(flow: flow, .failure(LoginError.exchangeFailed(
                        uiLanguageLocalized("login.keychainWriteFailed", defaultValue: "Unable to write to keychain"))))
                }
            } catch {
                self.deliverExchangeResult(flow: flow, .failure(LoginError.exchangeFailed(error.localizedDescription)))
            }
        }
    }

    /// Delivers a token-exchange result, but only if `flow` is still the current login flow. A prior
    /// flow's exchange can resolve after a re-entrant login() has already wrapped it up (with .cancelled)
    /// and installed a new completion; without this guard that orphaned result would call finish() and
    /// fire the *new* flow's completion with the *prior* flow's outcome (cross-flow mix-up). The normal
    /// single-login path always has `flow == flowID`, so behavior there is unchanged.
    private func deliverExchangeResult(flow: UInt64, _ result: Result<OAuthTokens, Error>) {
        guard flow == flowID else { return }
        finish(result)
    }

    // MARK: - Test seams (only @testable-visible, the public API is unchanged)

    /// For testing: performs the same re-entrant flow-identity transition as `login()` (wrap up any prior
    /// flow + stamp a fresh `flowID` + install the new completion), WITHOUT starting the loopback listener
    /// or opening a browser. Returns the new flow id so a test can mimic an exchange Task that captured it.
    func beginFlowForTesting(installing completion: @escaping (Result<OAuthTokens, Error>) -> Void) -> UInt64 {
        beginFlow(installing: completion)
        return flowID
    }

    /// For testing: drives the exact guarded delivery the token-exchange Task uses (same source as the
    /// `self.deliverExchangeResult(...)` calls inside `onCallback`), so a test can reproduce a late
    /// prior-flow result arriving after a re-entrant login without any real network round-trip.
    func deliverExchangeResultForTesting(flow: UInt64, _ result: Result<OAuthTokens, Error>) {
        deliverExchangeResult(flow: flow, result)
    }

    private func finish(_ result: Result<OAuthTokens, Error>) {
        timeoutTask?.cancel(); timeoutTask = nil
        listener?.cancel(); listener = nil
        pkce = nil; state = ""
        let c = completion; completion = nil
        c?(result)  // When completion is nil (no session in progress) the whole thing is a safe no-op
    }

    /// Gets a valid access token (refreshes with the refresh_token and stores it back if expired).
    func validTokens() async -> OAuthTokens? {
        guard let tokens = KeychainStore.loadChatGPTTokens() else { return nil }
        if !tokens.isExpired() { return tokens }
        guard !tokens.refreshToken.isEmpty else { return nil }
        do {
            let (data, resp) = try await URLSession.shared.data(
                for: ChatGPTOAuth.refreshRequest(refreshToken: tokens.refreshToken))
            let http = resp as? HTTPURLResponse
            guard let http, HTTPResponseValidator.successRange.contains(http.statusCode) else {
                // Refresh non-2xx: only log the status code, never print the response body (to avoid token leaks); behavior unchanged, still returns nil as usual.
                let status = http?.statusCode ?? -1
                NSLog("[SayIt][CodexLogin] token 刷新失败 status=%d", status)
                return nil
            }
            let refreshed = try ChatGPTOAuth.parseTokenResponse(data, fallbackRefresh: tokens.refreshToken)
            // The refresh token rotates: the old token is invalidated by the server once exchanged for a new value. If the new value is not persisted,
            // the keychain still holds the already-invalidated old token, and the next startup refresh will fail and log out. So return nil honestly on save failure,
            // not treating an unpersisted credential as success.
            guard KeychainStore.saveChatGPTTokens(refreshed) else {
                NSLog("[SayIt][CodexLogin] 刷新 token 持久化失败，放弃本次（避免轮换后未落盘致下次启动失效）")
                return nil
            }
            return refreshed
        } catch {
            // The refresh request threw (network/decoding, etc.): log the error to aid debugging (behavior unchanged, still returns nil as usual).
            NSLog("[SayIt][CodexLogin] token 刷新抛错 error=%@", String(describing: error))
            return nil
        }
    }
}
