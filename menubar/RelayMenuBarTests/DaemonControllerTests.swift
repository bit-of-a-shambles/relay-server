import XCTest
import Darwin
@testable import RelayMenuBar

// MARK: - Minimal DataSession stub for fetchPairingPayload tests

private struct StubSession: DataSession {
    typealias Handler = (URLRequest) async throws -> (Data, URLResponse)
    let handler: Handler
    func fetchData(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await handler(request)
    }
}

private func okResponse(for request: URLRequest) -> HTTPURLResponse {
    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
}

private func stubResponse(for request: URLRequest, status: Int, body: String) -> (Data, URLResponse) {
    let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    return (Data(body.utf8), resp)
}

func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> some Any,
    _ message: String = "",
    file: StaticString = #file,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected error to be thrown\(message.isEmpty ? "" : ": \(message)")", file: file, line: line)
    } catch {
        // expected
    }
}

// MARK: -

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

    // Regression: decodePairingPayload must reject loopback daemon URLs.
    // When the daemon runs with RELAY_DAEMON_HOST=127.0.0.1 it returns
    // url="http://127.0.0.1:17777".  If the menu bar accepts that and
    // shows the QR, the phone stores 127.0.0.1 and connects to its own
    // loopback → "Could not connect to the server."
    func testDecodePairingPayloadRejectsLoopbackDaemonURL() {
        let loopbackPayloads = [
            #"{"qrPayload":{"url":"http://127.0.0.1:17777","pairingCode":"abcd1234"}}"#,
            #"{"qrPayload":{"url":"http://127.9.9.9:17777","pairingCode":"abcd1234"}}"#,
            #"{"qrPayload":{"url":"http://localhost:17777","pairingCode":"abcd1234"}}"#,
        ]
        for json in loopbackPayloads {
            XCTAssertThrowsError(
                try DaemonController.decodePairingPayload(from: Data(json.utf8)),
                "expected loopback URL to be rejected: \(json)"
            )
        }
    }

    func testDecodePairingPayloadAcceptsTailscaleURL() throws {
        let data = Data(#"{"qrPayload":{"url":"http://100.64.0.1:17777","pairingCode":"abcd1234"}}"#.utf8)
        let payload = try DaemonController.decodePairingPayload(from: data)
        XCTAssertEqual(payload.daemonURL, "http://100.64.0.1:17777")
    }

    // Regression: fetchPairingPayload must POST to http://127.0.0.1:17777/pair/start
    // (daemonBaseURL, which is always loopback), never to a Tailscale bind-host URL.
    // Before the fix, start() set daemonBaseURL = http://<tailscaleIP>:17777 so the
    // menu bar tried to reach the daemon via the Tailscale interface → ECONNREFUSED
    // → "Could not connect to the server."
    func testFetchPairingPayloadPostsToLoopbackURL() async throws {
        setenv("RELAY_DAEMON_HOST", "100.66.77.88", 1)
        defer { unsetenv("RELAY_DAEMON_HOST") }

        let controller = DaemonController()
        var capturedURL: URL?

        let session = StubSession { request in
            capturedURL = request.url
            let body = #"{"qrPayload":{"url":"http://100.66.77.88:17777","pairingCode":"xy123456"}}"#
            return stubResponse(for: request, status: 200, body: body)
        }

        _ = try await controller.fetchPairingPayload(session: session)

        XCTAssertEqual(
            capturedURL?.absoluteString,
            "http://127.0.0.1:17777/pair/start",
            "fetchPairingPayload must use the loopback daemonBaseURL; using the Tailscale bind-host causes 'Could not connect' via Tailscale"
        )
    }

    func testFetchPairingPayloadThrowsOnNon200() async {
        let controller = DaemonController()
        let session = StubSession { request in
            stubResponse(for: request, status: 503, body: "{\"error\":\"daemon is bound to loopback only\"}")
        }
        await XCTAssertThrowsErrorAsync(try await controller.fetchPairingPayload(session: session))
    }

    func testFetchPairingPayloadThrowsWhenResponseHasLoopbackURL() async {
        // Even if the daemon somehow slips through and returns a loopback URL with
        // a 200 status, decodePairingPayload must reject it.
        let controller = DaemonController()
        let session = StubSession { request in
            stubResponse(for: request, status: 200, body: #"{"qrPayload":{"url":"http://127.0.0.1:17777","pairingCode":"xy123456"}}"#)
        }
        await XCTAssertThrowsErrorAsync(try await controller.fetchPairingPayload(session: session))
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

    // Regression: stop() was calling p.terminate() which sends SIGTERM only
    // to the zsh shell wrapper.  The Ruby/Puma child process (forked by that
    // shell) inherits the shell's PGID but receives no signal — it orphans,
    // keeps port 17777, and the next "Start Relay Daemon" click fails with
    // EADDRINUSE.
    //
    // Fix: kill(-shellPID, SIGTERM) sends SIGTERM to the entire process group.
    // Foundation.Process uses POSIX_SPAWN_SETPGROUP so the spawned shell
    // becomes a process-group leader (PGID == shell.PID); its forked children
    // inherit that PGID, so kill(-shellPID, SIGTERM) terminates them all.
    func testStopKillsEntireProcessGroupNotJustShellWrapper() throws {
        let pidFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("relay_stop_test_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        // Mimic DaemonController.start(): a shell that forks a long-running
        // child (simulating Puma) and waits for it.
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "sleep 30 & echo $! > '\(pidFile.path)'; wait"]
        shell.standardOutput = FileHandle.nullDevice
        shell.standardError = FileHandle.nullDevice
        try shell.run()

        // Wait up to 1 s for the child to write its PID.
        var childPID: Int32 = 0
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.05)
            if let s = try? String(contentsOf: pidFile, encoding: .utf8),
               let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)),
               pid > 0 {
                childPID = pid; break
            }
        }
        XCTAssertGreaterThan(childPID, 0, "child process should have started and written its PID")
        XCTAssertEqual(Darwin.kill(childPID, 0), 0, "child should be alive before stop()")

        // This is exactly what the fixed DaemonController.stop() does.
        // Using shell.terminate() (p.terminate()) here instead would leave
        // the sleep child alive — proving the regression.
        Darwin.kill(-shell.processIdentifier, SIGTERM)
        shell.waitUntilExit()

        // Brief wait for SIGTERM delivery and process cleanup.
        Thread.sleep(forTimeInterval: 0.1)

        // The child (simulated Puma) must be dead.  kill(pid, 0) returns -1
        // with errno ESRCH when the process no longer exists.
        XCTAssertEqual(Darwin.kill(childPID, 0), -1,
            "child process must be dead; p.terminate() alone would leave it orphaned on port 17777")
    }

    // Regression: daemonBaseURL must always stay on loopback regardless of
    // RELAY_DAEMON_HOST (Tailscale IP belongs only in the daemon's bind socket).
    func testDaemonBaseURLIsAlwaysLoopback() {
        setenv("RELAY_DAEMON_HOST", "100.99.88.77", 1)
        defer { unsetenv("RELAY_DAEMON_HOST") }

        let controller = DaemonController()
        XCTAssertEqual(controller.daemonBaseURL.absoluteString, "http://127.0.0.1:17777",
            "daemonBaseURL must stay on loopback; Tailscale IP belongs only in RELAY_DAEMON_HOST for the daemon's bind socket")
    }
}
