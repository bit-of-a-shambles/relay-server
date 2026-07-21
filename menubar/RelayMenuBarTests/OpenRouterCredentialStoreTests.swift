import XCTest
@testable import RelayMenuBar

final class OpenRouterCredentialStoreTests: XCTestCase {
    func testCredentialStoreRoundTripsAndDeletesKey() throws {
        let service = "dev.relay.menubar.tests.\(UUID().uuidString)"
        let store = KeychainOpenRouterCredentialStore(service: service)
        defer { try? store.delete() }

        XCTAssertNil(try store.read())
        try store.save("test-secret")
        XCTAssertEqual(try store.read(), "test-secret")
        try store.delete()
        XCTAssertNil(try store.read())
    }

    func testCredentialStoreRejectsBlankKey() {
        let store = KeychainOpenRouterCredentialStore(
            service: "dev.relay.menubar.tests.\(UUID().uuidString)"
        )

        XCTAssertThrowsError(try store.save("  \n "))
    }
}
