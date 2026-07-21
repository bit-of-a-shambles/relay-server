import SwiftUI

struct SettingsView: View {
    private let userDefaults: UserDefaults
    private let credentialStore: any OpenRouterCredentialStoring
    private let environmentAPIKey: String?

    @State private var bindHostOverride: String
    @State private var port: String
    @State private var agentCommandTemplate: String
    @State private var routerBaseURL: String
    @State private var anthropicAPIKey: String
    @State private var openRouterAPIKey = ""
    @State private var credentialSource: OpenRouterCredentialSource
    @State private var saved = false
    @State private var errorMessage: String?

    init(
        userDefaults: UserDefaults = .standard,
        credentialStore: any OpenRouterCredentialStoring = KeychainOpenRouterCredentialStore(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.userDefaults = userDefaults
        self.credentialStore = credentialStore
        environmentAPIKey = OpenRouterCredentialSource.environmentValue(in: environment)
        let config = DaemonLaunchConfig(defaults: userDefaults)
        _bindHostOverride = State(initialValue: config.bindHostOverride ?? "")
        _port = State(initialValue: String(config.port))
        _agentCommandTemplate = State(initialValue: config.agentCommandTemplate)
        _routerBaseURL = State(initialValue: config.routerBaseURL)
        _anthropicAPIKey = State(initialValue: config.anthropicAPIKey)
        let storedKey = (try? credentialStore.read()) ?? nil
        _credentialSource = State(
            initialValue: OpenRouterCredentialSource.resolve(
                keychainValue: storedKey,
                environment: environment
            )
        )
    }

    var body: some View {
        Form {
            Section("Daemon") {
                TextField("Bind host override", text: $bindHostOverride)
                    .textContentType(.URL)
                TextField("Port", text: $port)
                    .frame(width: 100)
                Text("Leave the host blank to use the first Tailscale address, or loopback when none is available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Agent") {
                TextField("Command template", text: $agentCommandTemplate)
                SecureField("Claude-compatible API key", text: $anthropicAPIKey)
                Text("Session routing uses the configured router base URL below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Router") {
                TextField("Router base URL", text: $routerBaseURL)
                SecureField(
                    credentialSource == .missing ? "OpenRouter API key" : "Store a different OpenRouter API key",
                    text: $openRouterAPIKey
                )
                Label(
                    credentialStatusText,
                    systemImage: credentialSource == .missing ? "exclamationmark.circle" : "checkmark.circle"
                )
                .foregroundStyle(credentialSource == .missing ? Color.secondary : Color.green)
                Text("Relay passes this key only to the local inference router.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if credentialSource == .environment {
                    Button("Save Environment Key to Keychain", systemImage: "key") {
                        importEnvironmentAPIKey()
                    }
                }
                if credentialSource == .keychain {
                    Button("Remove API Key", systemImage: "trash", role: .destructive) {
                        removeOpenRouterAPIKey()
                    }
                }
            }

            HStack {
                Button("Save Settings") {
                    save()
                }
                if saved {
                    Text("Saved")
                        .foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button("Open Logs") {
                    DaemonController().openLogsFolder()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 460)
    }

    private func save() {
        do {
            let trimmedKey = openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedKey.isEmpty {
                try credentialStore.save(trimmedKey)
                openRouterAPIKey = ""
                credentialSource = .keychain
            }

            let config = DaemonLaunchConfig(
                bindHostOverride: bindHostOverride,
                port: Int(port) ?? DaemonLaunchConfig.defaultPort,
                agentCommandTemplate: agentCommandTemplate,
                routerBaseURL: routerBaseURL,
                anthropicAPIKey: anthropicAPIKey
            )
            config.save(to: userDefaults)
            errorMessage = nil
            saved = true
            NotificationCenter.default.post(name: .relaySettingsDidChange, object: nil)
        } catch {
            saved = false
            errorMessage = error.localizedDescription
        }
    }

    private func removeOpenRouterAPIKey() {
        do {
            try credentialStore.delete()
            openRouterAPIKey = ""
            credentialSource = environmentAPIKey == nil ? .missing : .environment
            errorMessage = nil
            saved = true
            NotificationCenter.default.post(name: .relaySettingsDidChange, object: nil)
        } catch {
            saved = false
            errorMessage = error.localizedDescription
        }
    }

    private var credentialStatusText: String {
        switch credentialSource {
        case .keychain:
            return "Using API key stored in Keychain"
        case .environment:
            return "Using OPENROUTER_API_KEY from the app environment"
        case .missing:
            return "API key required"
        }
    }

    private func importEnvironmentAPIKey() {
        guard let environmentAPIKey else { return }
        do {
            try credentialStore.save(environmentAPIKey)
            credentialSource = .keychain
            errorMessage = nil
            saved = true
            NotificationCenter.default.post(name: .relaySettingsDidChange, object: nil)
        } catch {
            saved = false
            errorMessage = error.localizedDescription
        }
    }
}
