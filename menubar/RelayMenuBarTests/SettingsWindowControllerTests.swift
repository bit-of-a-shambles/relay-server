import SwiftUI
import XCTest
@testable import RelayMenuBar

final class SettingsWindowControllerTests: XCTestCase {
    @MainActor
    func testShowSettingsCreatesVisibleReusableWindow() {
        let controller = SettingsWindowController {
            AnyView(Text("Settings test content"))
        }

        controller.showSettings()
        let firstWindow = controller.window
        XCTAssertNotNil(firstWindow)
        XCTAssertTrue(firstWindow?.isVisible == true)
        XCTAssertTrue(firstWindow?.canBecomeKey == true)
        XCTAssertEqual(firstWindow?.title, "Relay Settings")

        controller.showSettings()

        XCTAssertIdentical(controller.window, firstWindow)
        firstWindow?.close()
        XCTAssertFalse(firstWindow?.isVisible == true)

        controller.showSettings()

        XCTAssertIdentical(controller.window, firstWindow)
        XCTAssertTrue(firstWindow?.isVisible == true)
        firstWindow?.close()
    }
}
