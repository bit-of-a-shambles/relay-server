import SwiftUI

@main
struct RelayMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            Text("Relay Menu Bar")
                .padding()
                .frame(width: 300, height: 120)
        }
    }
}
