import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let daemon = DaemonController()

    private let startStopItem = NSMenuItem(title: "Start Relay Daemon", action: #selector(toggleDaemon), keyEquivalent: "s")
    private let pairItem = NSMenuItem(title: "Show Pairing Code", action: #selector(showPairingCode), keyEquivalent: "p")
    private let logsItem = NSMenuItem(title: "Open Task Logs", action: #selector(openLogs), keyEquivalent: "l")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "bolt.horizontal.circle", accessibilityDescription: "Relay")
            button.toolTip = "Relay"
        }

        let menu = NSMenu()
        startStopItem.target = self
        pairItem.target = self
        logsItem.target = self

        menu.addItem(startStopItem)
        menu.addItem(pairItem)
        menu.addItem(logsItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q").target = self

        statusItem.menu = menu
        refreshMenuState()
    }

    @objc private func toggleDaemon() {
        do {
            if daemon.isRunning {
                daemon.stop()
            } else {
                try daemon.start()
            }
            refreshMenuState()
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func showPairingCode() {
        Task {
            do {
                let code = try await daemon.fetchPairingCode()
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Relay Pairing Code"
                    alert.informativeText = code
                    alert.alertStyle = .informational
                    alert.runModal()
                }
            } catch {
                await MainActor.run {
                    self.showError(error.localizedDescription)
                }
            }
        }
    }

    @objc private func openLogs() {
        daemon.openLogsFolder()
    }

    @objc private func quit() {
        daemon.stop()
        NSApp.terminate(nil)
    }

    private func refreshMenuState() {
        startStopItem.title = daemon.isRunning ? "Stop Relay Daemon" : "Start Relay Daemon"
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Relay Menu Bar Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
