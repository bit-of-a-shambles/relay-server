import XCTest
@testable import RelayMenuBar

// M58: installed-daemon discovery, direct-vs-shell launch selection, and
// DaemonLaunchConfig persistence.
final class DaemonLaunchTests: XCTestCase {
    private let brewARM = "/opt/homebrew/opt/relay/bin/relay-daemon"
    private let brewIntel = "/usr/local/opt/relay/bin/relay-daemon"

    // MARK: - resolveDaemonLaunch ordering

    func testResolveDaemonLaunchPrefersExistingEnvBinOverride() {
        let launch = DaemonController.resolveDaemonLaunch(
            env: ["RELAY_DAEMON_BIN": "/custom/relay-daemon"],
            exists: { $0 == "/custom/relay-daemon" || $0 == self.brewARM },
            cwd: "/",
            sourcePath: "/irrelevant/File.swift"
        )
        XCTAssertEqual(launch, .installed(binaryPath: "/custom/relay-daemon"))
    }

    func testResolveDaemonLaunchIgnoresMissingOrBlankEnvBinOverride() {
        // A nonexistent override falls through to the brew paths, mirroring
        // resolveRepoRoot's treatment of an invalid RELAY_REPO_ROOT.
        let missing = DaemonController.resolveDaemonLaunch(
            env: ["RELAY_DAEMON_BIN": "/gone/relay-daemon"],
            exists: { $0 == self.brewARM },
            cwd: "/",
            sourcePath: "/irrelevant/File.swift"
        )
        XCTAssertEqual(missing, .installed(binaryPath: brewARM))

        let blank = DaemonController.resolveDaemonLaunch(
            env: ["RELAY_DAEMON_BIN": "   "],
            exists: { $0 == self.brewARM },
            cwd: "/",
            sourcePath: "/irrelevant/File.swift"
        )
        XCTAssertEqual(blank, .installed(binaryPath: brewARM))
    }

    func testResolveDaemonLaunchPrefersAppleSiliconBrewPathOverIntel() {
        let launch = DaemonController.resolveDaemonLaunch(
            env: [:],
            exists: { $0 == self.brewARM || $0 == self.brewIntel },
            cwd: "/",
            sourcePath: "/irrelevant/File.swift"
        )
        XCTAssertEqual(launch, .installed(binaryPath: brewARM))
    }

    func testResolveDaemonLaunchUsesIntelBrewPathWhenAppleSiliconMissing() {
        let launch = DaemonController.resolveDaemonLaunch(
            env: [:],
            exists: { $0 == self.brewIntel },
            cwd: "/",
            sourcePath: "/irrelevant/File.swift"
        )
        XCTAssertEqual(launch, .installed(binaryPath: brewIntel))
    }

    // Milestone done-when: a fake relay-daemon at a temp "opt" path is picked
    // by the resolver (via the RELAY_DAEMON_BIN override against a real file).
    func testResolveDaemonLaunchPicksFakeBinaryAtTempOptPath() throws {
        let optDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("relay_m58_opt_\(UUID().uuidString)/opt/relay/bin")
        try FileManager.default.createDirectory(at: optDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: optDir) }
        let fakeBin = optDir.appendingPathComponent("relay-daemon")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fakeBin)

        let launch = DaemonController.resolveDaemonLaunch(
            env: ["RELAY_DAEMON_BIN": fakeBin.path],
            exists: { FileManager.default.fileExists(atPath: $0) },
            cwd: "/",
            sourcePath: "/irrelevant/File.swift"
        )
        XCTAssertEqual(launch, .installed(binaryPath: fakeBin.path))
    }

    func testResolveDaemonLaunchFallsBackToDevCheckout() {
        let launch = DaemonController.resolveDaemonLaunch(
            env: ["RELAY_REPO_ROOT": "/repo"],
            exists: { $0 == "/repo/daemon/bin/daemon" },
            cwd: "/",
            sourcePath: "/irrelevant/File.swift"
        )
        XCTAssertEqual(launch, .devCheckout(repoRoot: "/repo"))
    }

    // MARK: - launchSpec: direct vs shell

    func testLaunchSpecForInstalledRunsBinaryDirectlyWithEnvironment() {
        let spec = DaemonController.launchSpec(
            for: .installed(binaryPath: brewARM),
            host: "100.66.254.122",
            agentCommand: "claude -p {prompt}"
        )

        XCTAssertEqual(spec.executablePath, brewARM, "installed daemon must be exec'd directly, not via a shell")
        XCTAssertTrue(spec.arguments.isEmpty)
        XCTAssertEqual(spec.extraEnvironment["RELAY_DAEMON_HOST"], "100.66.254.122")
        XCTAssertEqual(spec.extraEnvironment["RELAY_DAEMON_PORT"], "17777")
        XCTAssertEqual(spec.extraEnvironment["RELAY_AGENT_COMMAND"], "claude -p {prompt}")
        XCTAssertEqual(spec.extraEnvironment["ANTHROPIC_BASE_URL"], "http://127.0.0.1:7778/api")
        XCTAssertEqual(spec.extraEnvironment["ANTHROPIC_API_KEY"], "relay-dummy")
    }

    func testLaunchSpecForDevCheckoutUsesZshWrapper() {
        let spec = DaemonController.launchSpec(
            for: .devCheckout(repoRoot: "/Users/test/relay"),
            host: "100.66.254.122",
            agentCommand: DaemonLaunchConfig.defaultAgentCommand
        )

        XCTAssertEqual(spec.executablePath, "/bin/zsh")
        XCTAssertEqual(spec.arguments.first, "-lc")
        XCTAssertEqual(spec.arguments.count, 2)
        let command = spec.arguments.last ?? ""
        XCTAssertTrue(command.contains("cd '/Users/test/relay'/daemon"))
        XCTAssertTrue(command.contains("bundle exec ruby bin/daemon"))
        XCTAssertTrue(spec.extraEnvironment.isEmpty, "dev path inlines env into the shell command")
    }

    func testDaemonCommandEscapesUserEditedAgentCommand() {
        let command = DaemonController.daemonCommand(
            repoRootPath: "/Users/test/relay",
            host: "100.66.254.122",
            agentCommand: "run '{prompt}' fast"
        )
        XCTAssertTrue(
            command.contains("RELAY_AGENT_COMMAND='run '\\''{prompt}'\\'' fast'"),
            "single quotes in a user-edited agent command must be shell-escaped: \(command)"
        )
    }

    // MARK: - preferredBindHost override

    func testPreferredBindHostUsesConfigOverrideBeforeEnvironment() {
        setenv("RELAY_DAEMON_HOST", "192.168.1.50", 1)
        defer { unsetenv("RELAY_DAEMON_HOST") }

        XCTAssertEqual(DaemonController.preferredBindHost(override: "100.64.9.9"), "100.64.9.9")
        XCTAssertEqual(
            DaemonController.preferredBindHost(override: "  "), "192.168.1.50",
            "blank override falls through to the environment"
        )
    }

    // MARK: - DaemonLaunchConfig persistence

    private func makeSuiteDefaults() throws -> (UserDefaults, String) {
        let suite = "relay-menubar-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (defaults, suite)
    }

    func testDaemonLaunchConfigDefaultsWhenUnset() throws {
        let (defaults, suite) = try makeSuiteDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let config = DaemonLaunchConfig.load(from: defaults)
        XCTAssertEqual(config.bindHostOverride, "")
        XCTAssertEqual(config.agentCommand, DaemonLaunchConfig.defaultAgentCommand)
    }

    func testDaemonLaunchConfigRoundTripsThroughUserDefaults() throws {
        let (defaults, suite) = try makeSuiteDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        var config = DaemonLaunchConfig.load(from: defaults)
        config.bindHostOverride = "100.64.1.2"
        config.agentCommand = "claude -p {prompt} --dangerously-skip-permissions"
        config.save(to: defaults)

        XCTAssertEqual(DaemonLaunchConfig.load(from: defaults), config)
    }

    func testDaemonLaunchConfigBlankStoredAgentCommandFallsBackToDefault() throws {
        let (defaults, suite) = try makeSuiteDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("   ", forKey: DaemonLaunchConfig.agentCommandKey)
        XCTAssertEqual(
            DaemonLaunchConfig.load(from: defaults).agentCommand,
            DaemonLaunchConfig.defaultAgentCommand,
            "a blanked-out agent command must not launch the daemon with an empty template"
        )
    }

    func testOpenRouterKeyPresent() {
        XCTAssertTrue(DaemonLaunchConfig.openRouterKeyPresent(env: ["OPENROUTER_API_KEY": "sk-or-x"]))
        XCTAssertFalse(DaemonLaunchConfig.openRouterKeyPresent(env: ["OPENROUTER_API_KEY": "  "]))
        XCTAssertFalse(DaemonLaunchConfig.openRouterKeyPresent(env: [:]))
    }
}
