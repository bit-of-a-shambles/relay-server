import AppKit
import SwiftUI

protocol SettingsWindowOpening: AnyObject {
    func showSettings()
}

final class SettingsWindowController: SettingsWindowOpening {
    private let content: () -> AnyView
    private(set) var window: NSWindow?

    init(content: @escaping () -> AnyView = { AnyView(SettingsView()) }) {
        self.content = content
    }

    func showSettings() {
        let settingsWindow = window ?? makeWindow()
        window = settingsWindow
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow.center()
        settingsWindow.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let hostingController = NSHostingController(rootView: content())
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Relay Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 520, height: 520))
        window.minSize = NSSize(width: 460, height: 420)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        return window
    }
}
