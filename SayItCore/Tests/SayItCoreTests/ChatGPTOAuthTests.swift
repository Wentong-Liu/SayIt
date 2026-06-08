import XCTest
@testable import SayItCore

/// ChatGPTOAuth unit test: pins the `ui_locales` OIDC hint on the authorize URL so the IdP login
/// page follows the app's selected UI language. Isolated with a separate UserDefaults(suiteName)
/// because `authorizeURL` reads the language via `AppConfig.persistedUILanguage(.standard)`; the test
/// sets `ui.language` in `.standard`, asserts, then restores the prior value in tearDown so it never
/// leaks into other tests or the developer's real preference.
final class ChatGPTOAuthTests: XCTestCase {
    private let key = "ui.language"
    private var previousRaw: String?

    override func setUp() {
        super.setUp()
        previousRaw = UserDefaults.standard.string(forKey: key)
    }

    override func tearDown() {
        if let previousRaw {
            UserDefaults.standard.set(previousRaw, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        previousRaw = nil
        super.tearDown()
    }

    private func authorizeQueryItems(uiLanguageRaw: String) -> [URLQueryItem] {
        UserDefaults.standard.set(uiLanguageRaw, forKey: key)
        let pkce = PKCE(verifier: "test-verifier")
        let url = ChatGPTOAuth.authorizeURL(pkce: pkce, state: "state-123")
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    }

    func testAuthorizeURLCarriesUILocalesEnglish() {
        let items = authorizeQueryItems(uiLanguageRaw: "en")
        XCTAssertEqual(items.first(where: { $0.name == "ui_locales" })?.value, "en")
    }

    func testAuthorizeURLCarriesUILocalesSimplifiedChinese() {
        let items = authorizeQueryItems(uiLanguageRaw: "zh-Hans")
        XCTAssertEqual(items.first(where: { $0.name == "ui_locales" })?.value, "zh-Hans")
    }

    func testAuthorizeURLPreservesExistingQueryItems() {
        // Adding ui_locales must not disturb the existing required OAuth/PKCE parameters.
        let items = authorizeQueryItems(uiLanguageRaw: "en")
        let names = Set(items.map(\.name))
        for required in ["response_type", "client_id", "redirect_uri", "scope",
                         "code_challenge", "code_challenge_method", "state", "originator"] {
            XCTAssertTrue(names.contains(required), "missing query item \(required)")
        }
    }
}
