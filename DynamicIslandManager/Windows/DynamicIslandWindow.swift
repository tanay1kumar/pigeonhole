import Cocoa
import SwiftUI

class DynamicIslandWindow: NSWindow {
    // expansion state for click through
    var isExpanded = false {
        didSet {
            self.ignoresMouseEvents = !isExpanded
        }
    }

    // dragging state for file drops
    var isDragging = false {
        didSet {
            if isDragging && isExpanded {
                self.makeKeyAndOrderFront(nil)
            } else if !isDragging && self.isKeyWindow {
                self.resignKey()
            }
        }
    }

    init() {
        // window size for expanded state plus padding
        let windowWidth = DesignConstants.expandedWidth + DesignConstants.windowPadding
        let windowHeight = DesignConstants.expandedHeight + DesignConstants.windowPadding
        let initialFrame = NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight)

        super.init(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // window config
        self.level = .statusBar + 1
        self.isOpaque = false
        self.backgroundColor = .clear
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        self.acceptsMouseMovedEvents = true
        self.hasShadow = false

        self.positionWindow()
    }

    // need these for file drops to work
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    func positionWindow() {
        guard let screen = NSScreen.main else { return }

        let windowWidth = DesignConstants.expandedWidth + DesignConstants.windowPadding
        let windowHeight = DesignConstants.expandedHeight + DesignConstants.windowPadding

        let leftWidth = screen.auxiliaryTopLeftArea?.width ?? 0
        let rightWidth = screen.auxiliaryTopRightArea?.width ?? 0
        let notchWidth = screen.frame.width - leftWidth - rightWidth
        let notchCenterX = leftWidth + (notchWidth / 2)

        let x = notchCenterX - (windowWidth / 2)
        let y = screen.frame.height - windowHeight + 10

        self.setFrame(NSRect(x: x, y: y, width: windowWidth, height: windowHeight), display: true)
    }

    // hit-test rects from the window itself, so they follow it to whatever screen it's on
    var islandFrame: NSRect {
        frame.insetBy(dx: DesignConstants.windowPadding / 2, dy: DesignConstants.windowPadding / 2)
    }

    var pillFrame: NSRect {
        NSRect(x: frame.midX - DesignConstants.collapsedWidth / 2,
               y: frame.maxY - DesignConstants.windowPadding / 2 - DesignConstants.collapsedHeight,
               width: DesignConstants.collapsedWidth,
               height: DesignConstants.collapsedHeight)
    }

    func getCollapsedNotchFrame() -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(x: 650, y: 924, width: 170, height: 32)
        }

        let notchX = (screen.frame.width - DesignConstants.collapsedWidth) / 2
        let notchY = screen.frame.height - DesignConstants.collapsedHeight

        return NSRect(x: notchX, y: notchY,
                     width: DesignConstants.collapsedWidth,
                     height: DesignConstants.collapsedHeight)
    }

    func getExpandedNotchFrame() -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(x: 545, y: 700, width: 380, height: 256)
        }

        let expandedX = (screen.frame.width - DesignConstants.expandedWidth) / 2
        let expandedY = screen.frame.height - DesignConstants.expandedHeight

        return NSRect(x: expandedX, y: expandedY,
                     width: DesignConstants.expandedWidth,
                     height: DesignConstants.expandedHeight)
    }
}
