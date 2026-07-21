import XCTest
@testable import RelayMenuBar

final class OpenRouterCredentialSourceTests: XCTestCase {
    func testKeychainCredentialTakesPrecedenceOverEnvironment() {
        XCTAssertEqual(
            OpenRouterCredentialSource.resolve(
                keychainValue: "stored-key",
                environment: ["OPENROUTER_API_KEY": "environment-key"]
            ),
            .keychain
        )
    }

    func testEnvironmentCredentialIsRecognizedWhenKeychainIsEmpty() {
        XCTAssertEqual(
            OpenRouterCredentialSource.resolve(
                keychainValue: nil,
                environment: ["OPENROUTER_API_KEY": " environment-key "]
            ),
            .environment
        )
    }

    func testBlankCredentialsAreTreatedAsMissing() {
        XCTAssertEqual(
            OpenRouterCredentialSource.resolve(
                keychainValue: "  ",
                environment: ["OPENROUTER_API_KEY": "\n"]
            ),
            .missing
        )
    }
}
