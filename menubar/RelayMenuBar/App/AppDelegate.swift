import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let daemon = DaemonController()

    private let startStopItem = NSMenuItem(title: "Start Relay Daemon", action: #selector(toggleDaemon), keyEquivalent: "s")
    private let pairItem = NSMenuItem(title: "Show Pairing Code", action: #selector(showPairingCode), keyEquivalent: "p")
    private let logsItem = NSMenuItem(title: "Open Task Logs", action: #selector(openLogs), keyEquivalent: "l")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "Relay"
            if let image = NSImage(systemSymbolName: "bolt.horizontal.circle", accessibilityDescription: "Relay") {
                button.image = image
            }
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
                let payload = try await daemon.fetchPairingPayload()
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Relay Pairing Code"
                    alert.informativeText = payload.pairingCode
                    alert.alertStyle = .informational
                    alert.accessoryView = makePairingAccessoryView(payload: payload)
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

    private func makePairingAccessoryView(payload: DaemonController.PairingPayload) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        if let image = makeQRCodeImage(from: payload.qrContent()) {
            let imageView = NSImageView(image: image)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                imageView.widthAnchor.constraint(equalToConstant: 180),
                imageView.heightAnchor.constraint(equalToConstant: 180)
            ])
            stack.addArrangedSubview(imageView)
        }

        let hint = NSTextField(labelWithString: "Scan with Relay iPhone app")
        hint.alignment = .center
        hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hint)

        // NSAlert requires the accessory view to have a concrete frame
        stack.frame = NSRect(x: 0, y: 0, width: 200, height: 210)

        return stack
    }

    private func makeQRCodeImage(from text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else {
            return nil
        }

        let scaled = output.transformed(by: CGAffineTransform(scaleX: 9, y: 9))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
