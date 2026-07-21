import XCTest
@testable import RelayMenuBar

private final class SettingsWindowOpenerSpy: SettingsWindowOpening {
    private(set) var showCallCount = 0

    func showSettings() {
        showCallCount += 1
    }
}

final class AppDelegateTests: XCTestCase {
    func testStatusMenuWiresEveryCommandToDelegate() {
        let delegate = AppDelegate(settingsWindowOpener: SettingsWindowOpenerSpy())
        let menu = delegate.makeStatusMenu()

        let expectedCommands: [(String, Selector, String)] = [
            ("Start Relay Daemon", NSSelectorFromString("toggleDaemon"), "s"),
            ("Show Pairing Code", NSSelectorFromString("showPairingCode"), "p"),
            ("Open Run Logs", NSSelectorFromString("openLogs"), "l"),
            ("Settings...", #selector(AppDelegate.openSettings), ","),
            ("Quit", NSSelectorFromString("quit"), "q")
        ]

        for (title, action, keyEquivalent) in expectedCommands {
            let item = menu.items.first { $0.title == title }
            XCTAssertNotNil(item, "Missing \(title)")
            XCTAssertIdentical(item?.target, delegate)
            XCTAssertEqual(item?.action, action)
            XCTAssertEqual(item?.keyEquivalent, keyEquivalent)
            XCTAssertTrue(item?.isEnabled == true)
        }

        XCTAssertEqual(menu.items.filter(\.isSeparatorItem).count, 1)
    }

    func testOpenSettingsShowsSettingsWindow() {
        let opener = SettingsWindowOpenerSpy()
        let delegate = AppDelegate(settingsWindowOpener: opener)

        delegate.openSettings()

        XCTAssertEqual(opener.showCallCount, 1)
    }
}
