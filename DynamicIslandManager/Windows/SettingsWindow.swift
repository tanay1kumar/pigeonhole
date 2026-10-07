import AppKit
import SwiftUI

extension Notification.Name {
    // the card's choose folders buttons, settings on destinations
    static let showDestinationSetup = Notification.Name("showDestinationSetup")
    // the settings tile, the menu bar item and command comma
    static let showSettings = Notification.Name("showSettings")
}

// the panes, in toolbar order
enum SettingsPane: String, CaseIterable {
    case general, destinations, account, about

    var title: String {
        switch self {
        case .general: return "General"
        case .destinations: return "Destinations"
        case .account: return "Account"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .destinations: return "folder"
        case .account: return "person.crop.circle"
        case .about: return "info.circle"
        }
    }
}

// apple's settings look, a toolbar of panes and the window title following the pane
final class SettingsWindow: NSWindow {
    private let tabs = SettingsTabs()

    // general fits without scrolling, destinations' list scrolls past four folders
    static let contentSize = NSSize(width: 560, height: 480)

    init(panes: [SettingsPane: NSViewController]) {
        // read first, adding the tabs selects general and saves it over this
        let last = AppDefaults.shared.string(forKey: AppDefaults.settingsPaneKey).flatMap(SettingsPane.init(rawValue:)) ?? .general
        super.init(contentRect: NSRect(origin: .zero, size: Self.contentSize),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        tabs.tabStyle = .toolbar
        for pane in SettingsPane.allCases {
            guard let controller = panes[pane] else { continue }
            // the tab controller hands this title to the window
            controller.title = pane.title
            let item = NSTabViewItem(viewController: controller)
            item.label = pane.title
            item.identifier = pane.rawValue
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            tabs.addTabViewItem(item)
        }
        contentViewController = tabs
        // setting the controller resizes the window to its view, every pane gets this size
        setContentSize(Self.contentSize)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        show(last)
        center()
    }

    var currentPane: SettingsPane? {
        tabs.currentPane
    }

    func show(_ pane: SettingsPane) {
        tabs.select(pane)
        title = pane.title
    }
}

// remembers the pane someone picked
private final class SettingsTabs: NSTabViewController {
    var currentPane: SettingsPane? {
        guard tabViewItems.indices.contains(selectedTabViewItemIndex) else { return nil }
        return (tabViewItems[selectedTabViewItemIndex].identifier as? String).flatMap(SettingsPane.init(rawValue:))
    }

    func select(_ pane: SettingsPane) {
        guard let index = tabViewItems.firstIndex(where: { $0.identifier as? String == pane.rawValue }) else { return }
        selectedTabViewItemIndex = index
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        if let pane = currentPane {
            // the title follows the pane, the window doesn't pick it up on its own
            view.window?.title = pane.title
            AppDefaults.shared.set(pane.rawValue, forKey: AppDefaults.settingsPaneKey)
        }
    }
}
