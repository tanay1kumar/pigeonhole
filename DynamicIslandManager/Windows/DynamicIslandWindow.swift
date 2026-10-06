import Cocoa
import SwiftUI

// a panel can take keys without making the app active, a plain window can't
class DynamicIslandWindow: NSPanel {
    // expansion state for click through
    var isExpanded = false {
        didSet {
            updateClickThrough()
        }
    }

    // where hover last saw the pointer
    var pointer: NSPoint = .zero {
        didSet {
            updateClickThrough()
        }
    }

    // dragging state for file drops
    var isDragging = false {
        didSet {
            // in front for the drop, without the keyboard, escape and space still belong to the drag
            if isDragging && isExpanded {
                self.orderFrontRegardless()
            } else if !isDragging {
                giveBackKey()
            }
        }
    }

    // borrowed keys go back to the app in front with a resign
    // with this app in front a resign leaves appkit stuck on the island, so another window takes them,
    // or the island keeps them until a click elsewhere
    func giveBackKey() {
        guard isKeyWindow else { return }
        if NSRunningApplication.current.isActive {
            NSApp.orderedWindows.first { $0 !== self && $0.isVisible && $0.canBecomeKey }?.makeKey()
        } else {
            resignKey()
        }
    }

    // the screen and notch the island sits on
    private(set) var islandScreen: IslandScreen?
    var onScreenChange: ((IslandScreen) -> Void)?
    // height of the open island right now, it follows what's showing
    var islandHeight: () -> CGFloat = { DesignConstants.expandedHeight }
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init() {
        let initialFrame = NSRect(x: 0, y: 0, width: DesignConstants.windowWidth, height: DesignConstants.windowHeight)

        super.init(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // window config, the floating flag first since it sets its own level
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        // the app is never in front, a panel hides on deactivate by default
        hidesOnDeactivate = false
        self.level = .statusBar + 1
        self.isOpaque = false
        self.backgroundColor = .clear
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        self.acceptsMouseMovedEvents = true
        self.hasShadow = false

        self.positionWindow()

        // displays come and go, the lid closes, the mac wakes up
        let app = NotificationCenter.default
        observers.append((app, app.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.positionWindow()
            }
        }))
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.positionWindow()
            }
        }))
    }

    deinit {
        for (center, observer) in observers {
            center.removeObserver(observer)
        }
    }

    // open, only the island takes clicks and drops, the window is taller than a short island
    // mouse y counts from 1, so NSMouseInRect keeps the screen's top row inside
    private func updateClickThrough() {
        let ignores = !(isExpanded && NSMouseInRect(pointer, islandFrame, false))
        if ignoresMouseEvents != ignores {
            ignoresMouseEvents = ignores
        }
    }

    // borderless can't be key otherwise, hover needs it for the keys
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    // on the notched screen, or the menu bar screen when there isn't one
    func positionWindow() {
        guard let target = IslandScreen.current() else { return }
        let size = CGSize(width: DesignConstants.windowWidth, height: DesignConstants.windowHeight)
        let frame = target.windowFrame(size: size, overhang: DesignConstants.topOverhang)
        if frame != self.frame {
            setFrame(frame, display: true)
            print("island: on \(target.hasNotch ? "the notched" : "a plain") screen at \(Int(frame.minX)),\(Int(frame.minY))")
        }
        if target != islandScreen {
            islandScreen = target
            onScreenChange?(target)
        }
    }

    // hit-test rects from the window itself, so they follow it to whatever screen it's on
    var islandFrame: NSRect {
        let height = islandHeight()
        return NSRect(x: frame.midX - DesignConstants.expandedWidth / 2,
                      y: frame.maxY - DesignConstants.topOverhang - height,
                      width: DesignConstants.expandedWidth,
                      height: height)
    }

    // the notch, or the zone at the top center of a screen without one
    var pillFrame: NSRect {
        let notch = islandScreen?.notch ?? DesignConstants.fallbackNotch
        return NSRect(x: frame.midX - notch.width / 2,
                      y: frame.maxY - DesignConstants.topOverhang - notch.height,
                      width: notch.width,
                      height: notch.height)
    }
}
