import AppKit
import ServiceManagement

// the menu bar icon, the app has no dock icon
@MainActor
final class MenuBarItem: NSObject, NSMenuItemValidation {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let onSettings: () -> Void
    private let onActivity: () -> Void
    private let canShowActivity: () -> Bool

    init(onSettings: @escaping () -> Void, onActivity: @escaping () -> Void, canShowActivity: @escaping () -> Bool) {
        self.onSettings = onSettings
        self.onActivity = onActivity
        self.canShowActivity = canShowActivity
        super.init()
        if let button = item.button {
            let image = NSImage(systemSymbolName: "capsule.tophalf.filled", accessibilityDescription: "Dynamic Island")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Dynamic Island"
        }
        let menu = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let activity = NSMenuItem(title: "Activity", action: #selector(openActivity), keyEquivalent: "")
        activity.target = self
        menu.addItem(activity)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Dynamic Island", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        item.menu = menu
    }

    var menuTitles: [String] {
        item.menu?.items.map(\.title) ?? []
    }

    #if DEBUG
    // scenarios pick a menu item without opening the menu
    func debugChoose(_ title: String) {
        guard let menu = item.menu, let index = menu.items.firstIndex(where: { $0.title == title }) else { return }
        menu.performActionForItem(at: index)
    }
    #endif

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(openActivity) ? canShowActivity() : true
    }

    @objc private func openSettings() {
        onSettings()
    }

    @objc private func openActivity() {
        onActivity()
    }
}

// login item through SMAppService, which may refuse an app without a bundle id
@MainActor
enum LaunchAtLogin {
    // the last refusal, general shows open login items instead of the toggle once there is one
    static var lastError: String?

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var statusText: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "on"
        case .notRegistered: return "off"
        case .requiresApproval: return "needs approval in System Settings"
        case .notFound: return "not found"
        @unknown default: return "unknown"
        }
    }

    // nil when it worked, else the reason
    static func set(_ enabled: Bool) -> String? {
        #if DEBUG
        // a stray click in a check must never change the user's real login items
        if DebugScenarios.isScenarioRun {
            print("launch at login: skipped in a scenario run")
            return nil
        }
        #endif
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
            return nil
        } catch {
            // the toggle can show an old status, already being that way isn't a refusal
            if isEnabled == enabled {
                lastError = nil
                return nil
            }
            let nsError = error as NSError
            print("launch at login: \(enabled ? "register" : "unregister") failed, \(nsError.domain) \(nsError.code): \(nsError.localizedDescription)")
            lastError = nsError.localizedDescription
            return lastError
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
