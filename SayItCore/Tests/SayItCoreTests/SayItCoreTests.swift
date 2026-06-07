import XCTest
@testable import SayItCore

final class SayItCoreTests: XCTestCase {
    func testIdentifier() {
        XCTAssertEqual(SayItCore.identifier, "com.liuwentong.SayIt")
    }
}
