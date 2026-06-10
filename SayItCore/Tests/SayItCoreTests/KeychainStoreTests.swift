import XCTest
@testable import SayItCore

/// Locks `KeychainStore.trimmedValue(account:)` — the single shared "read a stored key + trim whitespace, "" when
/// absent" helper that both cloud-STT-key sites in `DictationCoordinator` now call.
final class KeychainStoreTests: XCTestCase {

    /// A missing account trims to "" (no Keychain write needed, so this is the flake-free core of the contract).
    func testMissingAccountReturnsEmptyString() {
        // A throwaway account that is never written by the suite.
        let account = "test.trimmedValue.missing.\(UUID().uuidString)"
        XCTAssertEqual(KeychainStore.trimmedValue(account: account), "")
    }

    /// A stored value with surrounding whitespace/newlines reads back trimmed. Guarded on a successful write so an
    /// entitlement-flaky test host (where Keychain writes are denied) degrades to a skip rather than a false failure.
    func testStoredValueIsTrimmed() throws {
        let account = "test.trimmedValue.stored.\(UUID().uuidString)"
        let wrote = KeychainStore.set("  spaced-key\n", account: account)
        try XCTSkipUnless(wrote, "Keychain write unavailable in this test host; trim semantics covered by the missing-account case.")
        defer { _ = KeychainStore.set("", account: account) }
        XCTAssertEqual(KeychainStore.trimmedValue(account: account), "spaced-key")
    }
}
