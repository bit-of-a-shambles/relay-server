import XCTest
@testable import RelayMenuBar

final class DaemonControllerTests: XCTestCase {
    func testShellEscapeHandlesSingleQuotes() {
        let value = "/tmp/it'works"
        let escaped = DaemonController.shellEscape(value)
        XCTAssertEqual(escaped, "'/tmp/it'\\''works'")
    }

    func testDaemonCommandUsesEscapedRepoPathAndExpectedShape() {
        let command = DaemonController.daemonCommand(
            repoRootPath: "/Users/test/relay",
            host: "100.66.254.122"
        )

        XCTAssertTrue(command.contains("cd '/Users/test/relay'/daemon"))
        XCTAssertTrue(command.contains("RELAY_DAEMON_HOST='100.66.254.122'"))
        XCTAssertTrue(command.contains("RELAY_DAEMON_PORT=17777"))
        XCTAssertTrue(command.contains("bundle exec ruby bin/daemon"))
        XCTAssertTrue(command.contains("RELAY_AGENT_COMMAND='claude -p {prompt} --permission-mode acceptEdits'"))
        XCTAssertTrue(command.contains("ANTHROPIC_BASE_URL=http://127.0.0.1:7778/api"))
        XCTAssertFalse(command.contains("rackup"))
    }

    func testPreferredBindHostFallsBackToLoopbackWhenEnvMissing() {
        let host = DaemonController.preferredBindHost()
        XCTAssertFalse(host.isEmpty)
    }

    func testPreferredBindHostUsesEnvironmentOverride() {
        setenv("RELAY_DAEMON_HOST", "192.168.88.13", 1)
        defer { unsetenv("RELAY_DAEMON_HOST") }

        XCTAssertEqual(DaemonController.preferredBindHost(), "192.168.88.13")
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

    func testResolveRepoRootPrefersValidEnvOverride() {
        let root = DaemonController.resolveRepoRoot(
            envRoot: "/repo",
            cwd: "/somewhere/menubar",
            sourcePath: "/build/X/Core/DaemonController.swift",
            exists: { $0 == "/repo/daemon/bin/daemon" }
        )
        XCTAssertEqual(root, "/repo")
    }

    func testResolveRepoRootUsesCwdParentWhenLaunchedFromMenubarDir() {
        let root = DaemonController.resolveRepoRoot(
            envRoot: nil,
            cwd: "/Users/x/relay/menubar",
            sourcePath: "/irrelevant/File.swift",
            exists: { $0 == "/Users/x/relay/daemon/bin/daemon" }
        )
        XCTAssertEqual(root, "/Users/x/relay")
    }

    func testResolveRepoRootWalksUpFromSourcePathWhenCwdUnhelpful() {
        // Mirrors a Finder double-click: cwd is "/", so resolution must fall back
        // to the compiled source location.
        let root = DaemonController.resolveRepoRoot(
            envRoot: "   ", // blank override is ignored
            cwd: "/",
            sourcePath: "/Users/x/relay/menubar/RelayMenuBar/Core/DaemonController.swift",
            exists: { $0 == "/Users/x/relay/daemon/bin/daemon" }
        )
        XCTAssertEqual(root, "/Users/x/relay")
    }

    func testResolveRepoRootFallsBackToCwdWhenNothingResolves() {
        let root = DaemonController.resolveRepoRoot(
            envRoot: nil,
            cwd: "/nowhere",
            sourcePath: "/a/b/File.swift",
            exists: { _ in false }
        )
        XCTAssertEqual(root, "/nowhere")
    }

    // Regression: start() previously overwrote daemonBaseURL with the Tailscale
    // bind host, causing "Connection refused" when the menu bar tried to reach the
    // daemon via the Tailscale interface instead of loopback.  daemonBaseURL must
    // always be loopback regardless of RELAY_DAEMON_HOST.
    func testDaemonBaseURLIsAlwaysLoopback() {
        setenv("RELAY_DAEMON_HOST", "100.99.88.77", 1)
        defer { unsetenv("RELAY_DAEMON_HOST") }

        let controller = DaemonController()
        XCTAssertEqual(controller.daemonBaseURL.absoluteString, "http://127.0.0.1:17777",
            "daemonBaseURL must stay on loopback; Tailscale IP belongs only in RELAY_DAEMON_HOST for the daemon's bind socket")
    }
}
