import SwiftUI

enum DesignConstants {
    // the open island, 3 tiles across
    static let expandedWidth: CGFloat = 380
    static let expandedHeight: CGFloat = 256      // the tallest surface, the window fits it

    // heights per surface, content starts below the notch band
    static let notchBand: CGFloat = 38
    static let homeHeight: CGFloat = 174
    static let singleCardHeight: CGFloat = 210
    static let statusHeight: CGFloat = 150

    // rounded corners
    static let expandedCornerRadius: CGFloat = 24
    static let notchCornerRadius: CGFloat = 10
    static let earRadius: CGFloat = 6

    // tiles
    static let tileSize: CGFloat = 100
    static let tileSpacing: CGFloat = 16

    // window, its top sits above the screen's top edge
    static let windowPadding: CGFloat = 20
    static let topOverhang: CGFloat = 10
    static let windowWidth = expandedWidth + windowPadding
    static let windowHeight = expandedHeight + windowPadding

    // until the screen says otherwise
    static let fallbackNotch = CGSize(width: 180, height: 32)

    static let hoverExitDelay: Double = 0.3
}
