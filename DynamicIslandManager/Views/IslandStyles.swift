import SwiftUI
import AppKit

// the one primary button, a capsule in the accent color
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(height: 26)
            .background(Capsule().fill(Color.accentColor.opacity(isEnabled ? 1 : 0.35)))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.press, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

// everything else, plain text in the secondary color
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
            .contentShape(Rectangle())
    }
}

// a menu that opens on click, no appkit popup button sitting in the island
struct MenuButton<Label: View>: View {
    let items: [MenuChoice]
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button {
            MenuPopup.show(items)
        } label: {
            label()
        }
        .buttonStyle(.plain)
    }
}

struct MenuChoice {
    let title: String
    var checked = false
    let action: () -> Void
}

// keeps the actions alive while the menu is open, popUp waits until it closes
@MainActor
final class MenuPopup: NSObject {
    private let choices: [MenuChoice]

    private init(_ choices: [MenuChoice]) {
        self.choices = choices
    }

    static func show(_ choices: [MenuChoice]) {
        guard !choices.isEmpty else { return }
        let popup = MenuPopup(choices)
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, choice) in choices.enumerated() {
            let item = NSMenuItem(title: choice.title, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = popup
            item.tag = index
            item.state = choice.checked ? .on : .off
            menu.addItem(item)
        }
        // at the pointer, like a context menu
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        withExtendedLifetime(popup) {}
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard choices.indices.contains(sender.tag) else { return }
        choices[sender.tag].action()
    }
}
