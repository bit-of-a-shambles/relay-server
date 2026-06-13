import XCTest
@testable import RelayMenuBar

final class DaemonControllerTests: XCTestCase {
    func testShellEscapeHandlesSingleQuotes() {
        let value = "/tmp/it'works"
        let escaped = DaemonController.shellEscape(value)
        XCTAssertEqual(escaped, "'/tmp/it'\\''works'")
    }

    func testDaemonCommandUsesEscapedRepoPathAndExpectedShape() {
        let command = DaemonController.daemonCommand(repoRootPath: "/Users/test/relay")

        XCTAssertTrue(command.contains("cd '/Users/test/relay'/daemon"))
        XCTAssertTrue(command.contains("RELAY_DAEMON_HOST=127.0.0.1"))
        XCTAssertTrue(command.contains("RELAY_DAEMON_PORT=17777"))
        XCTAssertTrue(command.contains("bundle exec rackup -p 17777 config.ru"))
    }

    func testPairingStartURLBuildsExpectedEndpoint() {
        let base = URL(string: "http://127.0.0.1:17777")!
        let url = DaemonController.pairingStartURL(baseURL: base)
        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:17777/pair/start")
    }
}
