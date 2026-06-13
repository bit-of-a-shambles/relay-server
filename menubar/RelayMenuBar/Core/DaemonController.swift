import AppKit
import Foundation

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
        let command = Self.daemonCommand(repoRootPath: root)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", command]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice

        try p.run()
        process = p
    }

    func stop() {
        guard let p = process else {
            return
        }

        if p.isRunning {
            p.terminate()
        }
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

    func fetchPairingPayload() async throws -> PairingPayload {
        var request = URLRequest(url: Self.pairingStartURL(baseURL: daemonBaseURL))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)
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
        let current = FileManager.default.currentDirectoryPath
        if current.hasSuffix("/menubar") {
            return URL(fileURLWithPath: current).deletingLastPathComponent().path
        }
        return current
    }

    static func daemonCommand(repoRootPath: String) -> String {
        let escaped = shellEscape(repoRootPath)
        return "cd \(escaped)/daemon && HOST=\"${RELAY_DAEMON_HOST:-$(tailscale ip -4 2>/dev/null | head -n 1)}\" && if [ -z \"$HOST\" ]; then HOST=127.0.0.1; fi && RELAY_DAEMON_HOST=\"$HOST\" RELAY_DAEMON_PORT=17777 bundle exec rackup -p 17777 config.ru"
    }

    static func pairingStartURL(baseURL: URL) -> URL {
        baseURL.appendingPathComponent("pair/start")
    }

    static func decodePairingPayload(from data: Data) throws -> PairingPayload {
        let decoded = try JSONDecoder().decode(PairStartResponse.self, from: data)
        guard let parsedURL = URL(string: decoded.qrPayload.url),
              let scheme = parsedURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw NSError(
                domain: "RelayMenuBar",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "pair/start returned invalid daemon URL"]
            )
        }
        return PairingPayload(daemonURL: decoded.qrPayload.url, pairingCode: decoded.qrPayload.pairingCode)
    }

    static func shellEscape(_ value: String) -> String {
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private struct PairStartResponse: Decodable {
    struct QrPayload: Decodable {
        let url: String
        let pairingCode: String
    }

    let qrPayload: QrPayload
}
