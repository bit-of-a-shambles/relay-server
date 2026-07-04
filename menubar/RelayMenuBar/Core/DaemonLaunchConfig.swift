import Foundation

/// User-editable daemon launch settings, persisted in UserDefaults and
/// surfaced in the Settings pane. Consumed by DaemonController when
/// building the daemon launch spec.
struct DaemonLaunchConfig: Equatable {
    static let defaultAgentCommand = "claude -p {prompt} --permission-mode acceptEdits"

    static let bindHostKey = "relay.bindHostOverride"
    static let agentCommandKey = "relay.agentCommand"

    /// Bind host for the daemon's listening socket. Blank means automatic
    /// (RELAY_DAEMON_HOST env, then first Tailscale interface, then loopback).
    var bindHostOverride: String

    /// Agent command template; {prompt} is replaced by the daemon.
    var agentCommand: String

    static func load(from defaults: UserDefaults) -> DaemonLaunchConfig {
        let storedAgent = defaults.string(forKey: agentCommandKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return DaemonLaunchConfig(
            bindHostOverride: defaults.string(forKey: bindHostKey) ?? "",
            agentCommand: storedAgent.isEmpty ? defaultAgentCommand : storedAgent
        )
    }

    func save(to defaults: UserDefaults) {
        defaults.set(bindHostOverride, forKey: Self.bindHostKey)
        defaults.set(agentCommand, forKey: Self.agentCommandKey)
    }

    /// Whether OPENROUTER_API_KEY is set in the app's environment — shown as
    /// a hint in Settings so users know the router will be able to dispatch.
    static func openRouterKeyPresent(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        !(env["OPENROUTER_API_KEY"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
