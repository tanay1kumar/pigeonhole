import SwiftUI

// every animation in the island comes from here
enum Motion {
    static let open = Animation.spring(duration: 0.36, bounce: 0.15)      // shape grows
    static let close = Animation.spring(duration: 0.28, bounce: 0)        // shape shrinks, no overshoot
    static let content = Animation.spring(duration: 0.26, bounce: 0)      // content swaps inside the island
    static let press = Animation.spring(duration: 0.18, bounce: 0)
    static let contentDelay = 0.06                                         // content starts after the shape
    static let contentLag = 0.02                                           // and is built at least this much later, past a 60 Hz frame
    static let fadeOut = Animation.easeOut(duration: 0.1)                  // content leaves first on close
    static let closeDelay = 0.04                                           // then the shape follows
    static let reduced = Animation.easeInOut(duration: 0.15)              // reduce motion, opacity only
}

private struct IslandReduceMotionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    // reduce motion as the island sees it, set once at its root
    var islandReduceMotion: Bool {
        get { self[IslandReduceMotionKey.self] }
        set { self[IslandReduceMotionKey.self] = newValue }
    }
}
