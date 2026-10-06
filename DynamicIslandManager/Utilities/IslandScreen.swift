import AppKit

// which screen the island lives on and where its notch is
// the built-in notched screen if there is one, else the menu bar screen (lid closed)
struct IslandScreen: Equatable {
    let frame: NSRect           // global coordinates
    let hasNotch: Bool
    // the notch, or on a screen without one the zone at the top that opens the island
    let notch: CGSize
    let notchCenterX: CGFloat   // global x

    // the hover zone on a screen without a notch
    static let plainZoneWidth: CGFloat = 200

    static func current() -> IslandScreen? {
        let screens = NSScreen.screens
        guard let screen = screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? screens.first else { return nil }
        return IslandScreen(screen)
    }

    init(_ screen: NSScreen) {
        self.init(frame: screen.frame, safeTop: screen.safeAreaInsets.top,
                  leftArea: screen.auxiliaryTopLeftArea?.width, rightArea: screen.auxiliaryTopRightArea?.width,
                  menuBarHeight: screen.frame.maxY - screen.visibleFrame.maxY)
    }

    // the menu bar height is 0 when it hides itself
    init(frame: NSRect, safeTop: CGFloat, leftArea: CGFloat?, rightArea: CGFloat?, menuBarHeight: CGFloat) {
        self.frame = frame
        if safeTop > 0, let leftArea, let rightArea, frame.width - leftArea - rightArea > 0 {
            hasNotch = true
            notch = CGSize(width: frame.width - leftArea - rightArea, height: safeTop)
            notchCenterX = frame.minX + leftArea + notch.width / 2
        } else {
            hasNotch = false
            notch = CGSize(width: Self.plainZoneWidth, height: menuBarHeight > 0 ? menuBarHeight : 24)
            notchCenterX = frame.midX
        }
    }

    // a window of this size centered on the notch, its top above the screen's top edge
    // no rounding, a 179 pt notch centers on a half point, a whole pixel at 2x
    func windowFrame(size: CGSize, overhang: CGFloat) -> NSRect {
        NSRect(x: notchCenterX - size.width / 2, y: frame.maxY - size.height + overhang,
               width: size.width, height: size.height)
    }
}
