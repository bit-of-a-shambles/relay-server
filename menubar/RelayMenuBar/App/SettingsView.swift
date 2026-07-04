import SwiftUI

/// Real Settings pane (replaces the placeholder scene): edits the
/// DaemonLaunchConfig persisted in UserDefaults. Changes apply the next
/// time the daemon is started from the menu.
struct SettingsView: View {
    @State private var config = DaemonLaunchConfig.load(from: .standard)

    var body: some View {
        Form {
            TextField("Bind host", text: $config.bindHostOverride, prompt: Text("automatic"))
                .help("Daemon listening address. Leave blank to auto-detect (RELAY_DAEMON_HOST, then Tailscale, then loopback).")

            TextField("Agent command", text: $config.agentCommand)
                .font(.system(.body, design: .monospaced))
                .help("Command template the daemon runs for each task; {prompt} is replaced with the task prompt.")

            LabeledContent(
                "OpenRouter key",
                value: DaemonLaunchConfig.openRouterKeyPresent() ? "Set" : "Not set"
            )

            Text("Changes take effect the next time the daemon is started.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button("Open Task Logs") {
                DaemonController.openLogsFolder()
            }
        }
        .padding(20)
        .frame(width: 440)
        .onChange(of: config) {
            config.save(to: .standard)
        }
    }
}
