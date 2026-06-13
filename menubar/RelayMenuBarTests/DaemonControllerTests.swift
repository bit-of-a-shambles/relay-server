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
        XCTAssertTrue(command.contains("tailscale ip -4"))
        XCTAssertTrue(command.contains("if [ -z \"$HOST\" ]; then HOST=127.0.0.1; fi"))
        XCTAssertTrue(command.contains("RELAY_DAEMON_HOST=\"$HOST\""))
        XCTAssertTrue(command.contains("RELAY_DAEMON_PORT=17777"))
        XCTAssertTrue(command.contains("bundle exec rackup -p 17777 config.ru"))
    }

    func testPairingStartURLBuildsExpectedEndpoint() {
        let base = URL(string: "http://127.0.0.1:17777")!
        let url = DaemonController.pairingStartURL(baseURL: base)
        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:17777/pair/start")
    }

    func testPairingPayloadQRCodeContentIncludesEncodedURLAndCode() {
        let payload = DaemonController.PairingPayload(
            daemonURL: "http://100.101.102.103:17777",
            pairingCode: "abc 123"
        )

        XCTAssertEqual(
            payload.qrContent(),
            "relay://pair?url=http://100.101.102.103:17777&code=abc%20123"
        )
    }

    func testDecodePairingPayloadAcceptsValidPayload() throws {
        let data = Data("{\"qrPayload\":{\"url\":\"http://100.101.102.103:17777\",\"pairingCode\":\"abcd1234\"}}".utf8)

        let payload = try DaemonController.decodePairingPayload(from: data)

        XCTAssertEqual(payload.daemonURL, "http://100.101.102.103:17777")
        XCTAssertEqual(payload.pairingCode, "abcd1234")
    }

    func testDecodePairingPayloadRejectsNonHttpUrl() {
        let data = Data("{\"qrPayload\":{\"url\":\"ftp://100.101.102.103:17777\",\"pairingCode\":\"abcd1234\"}}".utf8)

        XCTAssertThrowsError(try DaemonController.decodePairingPayload(from: data))
    }

    func testDecodePairingPayloadRejectsMalformedJson() {
        let data = Data("{}".utf8)

        XCTAssertThrowsError(try DaemonController.decodePairingPayload(from: data))
    }
}
