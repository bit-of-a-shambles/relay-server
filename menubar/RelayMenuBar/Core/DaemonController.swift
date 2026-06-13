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

// MARK: -

final class DaemonController {
    private var process: Process?
    private var isStarting = false

    private(set) var daemonBaseURL = URL(string: "http://127.0.0.1:17777")!

    var isRunning: Bool {
        process?.isRunning == true
    }

    func start() throws {
        if isRunning || isStarting {
            return
        }

        isStarting = true
        defer { isStarting = false }

        let root = repoRootPath()
        let bindHost = Self.preferredBindHost()
        // daemonBaseURL stays at http://127.0.0.1:17777 — the menu bar and daemon
        // are always on the same machine, so loopback is the correct local admin
        // address. The Tailscale bindHost is only for the daemon's own listening
        // socket (so the phone can reach it) and appears in the QR payload URL
        // that the daemon itself computes from RELAY_DAEMON_HOST.
        let command = Self.daemonCommand(repoRootPath: root, host: bindHost)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", command]
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
        let logs = NSString(string: "~/.relay/tasks").expandingTildeInPath
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: logs)
    }

    private func repoRootPath() -> String {
        Self.resolveRepoRoot(
            envRoot: ProcessInfo.processInfo.environment["RELAY_REPO_ROOT"],
            cwd: FileManager.default.currentDirectoryPath,
            sourcePath: #filePath,
            exists: { FileManager.default.fileExists(atPath: $0) }
        )
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

    static func daemonCommand(repoRootPath: String, host: String) -> String {
        let escaped = shellEscape(repoRootPath)
        // Launch via bin/daemon (not rackup): it binds to RELAY_DAEMON_HOST via
        // Puma --bind (rackup ignores the env var and binds loopback only) and
        // supervises the router. ANTHROPIC_* are inherited by the spawned agent
        // so Claude Code's calls route through the local router → OpenRouter.
        let env = [
            "RELAY_DAEMON_HOST=\(shellEscape(host))",
            "RELAY_DAEMON_PORT=17777",
            "RELAY_AGENT_COMMAND='claude -p {prompt} --permission-mode acceptEdits'",
            "ANTHROPIC_BASE_URL=http://127.0.0.1:7778/api",
            "ANTHROPIC_API_KEY=relay-dummy"
        ].joined(separator: " ")
        return "cd \(escaped)/daemon && \(env) bundle exec ruby bin/daemon"
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
