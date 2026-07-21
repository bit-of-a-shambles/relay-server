import AppKit
import Darwin
import Foundation

// MARK: - URLSession seam

protocol DataSession {
    func fetchData(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: DataSession {
    func fetchData(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request)
    }
}

struct DaemonLaunchConfig: Equatable {
    static let defaultPort = 17_777
    static let defaultAgentCommandTemplate = "claude -p {prompt} --permission-mode acceptEdits"
    static let defaultRouterBaseURL = "http://127.0.0.1:7778/api"
    static let defaultAnthropicAPIKey = "relay-dummy"

    private enum Key {
        static let bindHostOverride = "daemon.bindHostOverride"
        static let port = "daemon.port"
        static let agentCommandTemplate = "daemon.agentCommandTemplate"
        static let routerBaseURL = "daemon.routerBaseURL"
        static let anthropicAPIKey = "daemon.anthropicAPIKey"
    }

    var bindHostOverride: String?
    var port: Int
    var agentCommandTemplate: String
    var routerBaseURL: String
    var anthropicAPIKey: String

    init(
        bindHostOverride: String? = nil,
        port: Int = Self.defaultPort,
        agentCommandTemplate: String = Self.defaultAgentCommandTemplate,
        routerBaseURL: String = Self.defaultRouterBaseURL,
        anthropicAPIKey: String = Self.defaultAnthropicAPIKey
    ) {
        self.bindHostOverride = Self.normalized(bindHostOverride)
        self.port = port > 0 ? port : Self.defaultPort
        self.agentCommandTemplate = agentCommandTemplate
        self.routerBaseURL = routerBaseURL
        self.anthropicAPIKey = anthropicAPIKey
    }

    init(defaults: UserDefaults) {
        let storedHost = defaults.string(forKey: Key.bindHostOverride)
        let storedPort = defaults.integer(forKey: Key.port)
        self.init(
            bindHostOverride: storedHost,
            port: storedPort > 0 ? storedPort : Self.defaultPort,
            agentCommandTemplate: defaults.string(forKey: Key.agentCommandTemplate) ?? Self.defaultAgentCommandTemplate,
            routerBaseURL: defaults.string(forKey: Key.routerBaseURL) ?? Self.defaultRouterBaseURL,
            anthropicAPIKey: defaults.string(forKey: Key.anthropicAPIKey) ?? Self.defaultAnthropicAPIKey
        )
    }

    func save(to defaults: UserDefaults) {
        if let bindHostOverride {
            defaults.set(bindHostOverride, forKey: Key.bindHostOverride)
        } else {
            defaults.removeObject(forKey: Key.bindHostOverride)
        }
        defaults.set(port, forKey: Key.port)
        defaults.set(agentCommandTemplate, forKey: Key.agentCommandTemplate)
        defaults.set(routerBaseURL, forKey: Key.routerBaseURL)
        defaults.set(anthropicAPIKey, forKey: Key.anthropicAPIKey)
    }

    func processEnvironment(
        inherited: [String: String] = ProcessInfo.processInfo.environment,
        fallbackBindHost: String,
        openRouterAPIKey: String? = nil
    ) -> [String: String] {
        var environment = inherited
        environment["RELAY_DAEMON_HOST"] = bindHostOverride ?? fallbackBindHost
        environment["RELAY_DAEMON_PORT"] = String(port)
        environment["RELAY_AGENT_COMMAND"] = agentCommandTemplate
        if agentCommandTemplate == Self.defaultAgentCommandTemplate {
            environment["RELAY_CLAUDE_STREAMING"] = "1"
        } else {
            environment.removeValue(forKey: "RELAY_CLAUDE_STREAMING")
        }
        environment["RELAY_ROUTER_BASE_URL"] = routerBaseURL
        environment["ANTHROPIC_API_KEY"] = anthropicAPIKey
        if let key = Self.normalized(openRouterAPIKey) {
            environment["OPENROUTER_API_KEY"] = key
        }
        return environment
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum DaemonLaunch: Equatable {
    case direct(executablePath: String)
    case shell(command: String)
}

struct ProcessLaunchSpec: Equatable {
    let executablePath: String
    let arguments: [String]
    let environment: [String: String]
}

// MARK: -

final class DaemonController {
    private var process: Process?
    private var isStarting = false
    private let userDefaults: UserDefaults
    private let processFactory: (ProcessLaunchSpec) -> Process
    private let credentialStore: any OpenRouterCredentialStoring

    private(set) var daemonBaseURL: URL

    init(
        userDefaults: UserDefaults = .standard,
        credentialStore: any OpenRouterCredentialStoring = KeychainOpenRouterCredentialStore(),
        processFactory: @escaping (ProcessLaunchSpec) -> Process = DaemonController.makeProcess
    ) {
        self.userDefaults = userDefaults
        self.credentialStore = credentialStore
        self.processFactory = processFactory
        let config = DaemonLaunchConfig(defaults: userDefaults)
        daemonBaseURL = Self.daemonBaseURL(port: config.port)
    }

    var isRunning: Bool {
        process?.isRunning == true
    }

    func start() throws {
        if isRunning || isStarting {
            return
        }

        isStarting = true
        defer { isStarting = false }

        let config = DaemonLaunchConfig(defaults: userDefaults)

        // Kill any stale daemon occupying the configured port (e.g. from a manual terminal
        // start that pre-dates this menu bar session). If we don't do this the new
        // Puma process fails with EADDRINUSE and the port stays owned by the old,
        // potentially loopback-only process.
        Self.killPortOwner(config.port)

        let bindHost = config.bindHostOverride ?? Self.preferredBindHost()
        // daemonBaseURL stays on loopback — the menu bar and daemon
        // are always on the same machine, so loopback is the correct local admin
        // address. The Tailscale bindHost is only for the daemon's own listening
        // socket (so the phone can reach it) and appears in the QR payload URL
        // that the daemon itself computes from RELAY_DAEMON_HOST.
        daemonBaseURL = Self.daemonBaseURL(port: config.port)
        let launch = Self.resolveDaemonLaunch(
            env: ProcessInfo.processInfo.environment,
            exists: { FileManager.default.fileExists(atPath: $0) }
        )

        let processSpec = Self.processLaunchSpec(
            for: launch,
            environment: config.processEnvironment(
                fallbackBindHost: bindHost,
                openRouterAPIKey: try credentialStore.read()
            )
        )
        let p = processFactory(processSpec)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice

        try p.run()
        process = p
    }

    func stop() {
        guard let p = process else { return }
        // kill(-pgid, SIGTERM) sends SIGTERM to the entire process group so
        // the Ruby/Puma child (forked by the zsh wrapper) is also terminated.
        // p.terminate() calls kill(pid, SIGTERM) which only kills the shell;
        // Puma is orphaned, keeps port 17777, and the next Start fails with
        // EADDRINUSE.  Foundation.Process uses POSIX_SPAWN_SETPGROUP so the
        // shell becomes its own process-group leader (PGID == shell.PID), and
        // all children inherit that PGID — so kill(-shellPID, SIGTERM) reaches
        // the full shell+Puma subtree.
        Darwin.kill(-p.processIdentifier, SIGTERM)
        process = nil
    }

    struct PairingPayload {
        let daemonURL: String
        let pairingCode: String

        func qrContent() -> String {
            let encodedURL = daemonURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? daemonURL
            let encodedCode = pairingCode.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? pairingCode
            return "relay://pair?url=\(encodedURL)&code=\(encodedCode)"
        }

        func manualEntryText() -> String {
            "Mac URL: \(daemonURL)\nPairing code: \(pairingCode)"
        }
    }

    func fetchPairingPayload(
        session: any DataSession = URLSession.shared
    ) async throws -> PairingPayload {
        var request = URLRequest(url: Self.pairingStartURL(baseURL: daemonBaseURL))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.fetchData(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? "pair/start failed"
            throw NSError(domain: "RelayMenuBar", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
        }

        return try Self.decodePairingPayload(from: data)
    }

    func openLogsFolder() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: Self.logsFolderPath())
    }

    static func logsFolderPath(homeDirectory: String = NSHomeDirectory()) -> String {
        URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(".relay", isDirectory: true)
            .appendingPathComponent("runs", isDirectory: true)
            .path
    }

    private func repoRootPath() -> String {
        Self.resolveRepoRoot(
            envRoot: ProcessInfo.processInfo.environment["RELAY_REPO_ROOT"],
            cwd: FileManager.default.currentDirectoryPath,
            sourcePath: #filePath,
            exists: { FileManager.default.fileExists(atPath: $0) }
        )
    }

    static func resolveDaemonLaunch(
        env: [String: String],
        exists: (String) -> Bool
    ) -> DaemonLaunch {
        let installedCandidates: [String] = [
            env["RELAY_DAEMON_BIN"],
            "/opt/homebrew/opt/relay/bin/relay-daemon",
            "/usr/local/opt/relay/bin/relay-daemon"
        ].compactMap { candidate in
            guard let candidate, !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return candidate
        }

        if let installedPath = installedCandidates.first(where: exists) {
            return .direct(executablePath: installedPath)
        }

        let root = resolveRepoRoot(
            envRoot: env["RELAY_REPO_ROOT"],
            cwd: env["PWD"] ?? FileManager.default.currentDirectoryPath,
            sourcePath: #filePath,
            exists: exists
        )
        return .shell(command: daemonCommand(repoRootPath: root))
    }

    // Locate the relay repo (the dir containing daemon/bin/daemon) regardless of
    // how the menu bar app was launched. Order: RELAY_REPO_ROOT override, then
    // the working directory (terminal launch), then a walk up from the compiled
    // source path (#filePath points into the checkout the app was built from, so
    // this resolves even for a Finder double-click where cwd is "/").
    static func resolveRepoRoot(
        envRoot: String?,
        cwd: String,
        sourcePath: String,
        exists: (String) -> Bool
    ) -> String {
        func hasDaemon(_ root: String) -> Bool { exists(root + "/daemon/bin/daemon") }

        if let envRoot = envRoot?.trimmingCharacters(in: .whitespacesAndNewlines),
           !envRoot.isEmpty, hasDaemon(envRoot) {
            return envRoot
        }

        let cwdRoot = cwd.hasSuffix("/menubar")
            ? URL(fileURLWithPath: cwd).deletingLastPathComponent().path
            : cwd
        if hasDaemon(cwdRoot) {
            return cwdRoot
        }

        var dir = URL(fileURLWithPath: sourcePath).deletingLastPathComponent()
        for _ in 0..<8 {
            if hasDaemon(dir.path) {
                return dir.path
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }

        return cwdRoot
    }

    static func daemonCommand(repoRootPath: String) -> String {
        let escaped = shellEscape(repoRootPath)
        // Launch via bin/daemon (not rackup): the process environment supplies
        // its bind/router settings and bin/daemon supervises the router.
        return "cd \(escaped)/daemon && bundle exec ruby bin/daemon"
    }

    static func processLaunchSpec(
        for launch: DaemonLaunch,
        environment: [String: String]
    ) -> ProcessLaunchSpec {
        switch launch {
        case let .direct(executablePath):
            return ProcessLaunchSpec(
                executablePath: executablePath,
                arguments: [],
                environment: environment
            )
        case let .shell(command):
            return ProcessLaunchSpec(
                executablePath: "/bin/zsh",
                arguments: ["-lc", command],
                environment: environment
            )
        }
    }

    private static func makeProcess(from spec: ProcessLaunchSpec) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: spec.executablePath)
        process.arguments = spec.arguments
        process.environment = spec.environment
        return process
    }

    static func daemonBaseURL(port: Int) -> URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    static func pairingStartURL(baseURL: URL) -> URL {
        baseURL.appendingPathComponent("pair/start")
    }

    static func decodePairingPayload(from data: Data) throws -> PairingPayload {
        let decoded = try JSONDecoder().decode(PairStartResponse.self, from: data)
        guard let parsedURL = URL(string: decoded.qrPayload.url),
              let scheme = parsedURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = parsedURL.host,
              !isLoopback(host) else {
            throw NSError(
                domain: "RelayMenuBar",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "pair/start returned a loopback URL — restart the daemon with RELAY_DAEMON_HOST set to a Tailscale or LAN address"]
            )
        }
        return PairingPayload(daemonURL: decoded.qrPayload.url, pairingCode: decoded.qrPayload.pairingCode)
    }
}

extension DaemonController {
    private static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "::1" || host == "127.0.0.1" || host.hasPrefix("127.")
    }

    /// Kill whatever process is listening on `port` via SIGTERM to the process
    /// group, mirroring the same strategy used in stop().  Silently no-ops if
    /// the port is free or lsof is unavailable.
    static func killPortOwner(_ port: Int) {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-ti", "TCP:\(port)", "-sTCP:LISTEN"]
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in output.split(separator: "\n") {
            if let pid = Int32(line.trimmingCharacters(in: .whitespaces)) {
                Darwin.kill(-pid, SIGTERM)
                // Give the process a moment to exit before Puma tries to bind.
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
    }

    static func shellEscape(_ value: String) -> String {
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func preferredBindHost() -> String {
        let environmentHost = ProcessInfo.processInfo.environment["RELAY_DAEMON_HOST"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let environmentHost, !environmentHost.isEmpty {
            return environmentHost
        }

        if let tailscaleHost = firstInterfaceAddress(matchingPrefix: "100.") {
            return tailscaleHost
        }

        return "127.0.0.1"
    }

    private static func firstInterfaceAddress(matchingPrefix prefix: String) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        process.arguments = []
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else {
            return nil
        }

        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("inet ") else {
                continue
            }

            let fields = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2 else {
                continue
            }

            let ip = String(fields[1])
            if ip.hasPrefix(prefix) {
                return ip
            }
        }

        return nil
    }
}

private struct PairStartResponse: Decodable {
    struct QrPayload: Decodable {
        let url: String
        let pairingCode: String
    }

    let qrPayload: QrPayload
}
