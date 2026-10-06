import SwiftUI

@main
struct DynamicIslandManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        // command comma and the app menu's item go to the real settings window, not this empty scene
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appDelegate.showSettings(nil)
                }
                .keyboardShortcut(",")
            }
        }
    }
}
