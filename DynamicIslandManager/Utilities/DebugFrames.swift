import SwiftUI
import AppKit

// debug builds remember where named controls are, so scenarios can click the real buttons.
// release builds compile .debugFrame away to nothing.
#if DEBUG
@MainActor
enum DebugFrames {
    // per window root (debugFrameRoot), what's laid out in it right now. a preference rather than
    // onAppear/onDisappear: views that come and go with transitions left entries missing
    static var roots: [String: [String: CGRect]] = [:]

    // swiftui global space: top-left origin of the window's content view
    static var frames: [String: CGRect] {
        roots.values.reduce(into: [:]) { all, frames in
            all.merge(frames) { _, new in new }
        }
    }
}

// scenarios can stand in for the mouse without moving the real cursor
@MainActor
enum DebugPointer {
    static var override: NSPoint?
}

// what scenarios reach into that the views own
@MainActor
enum DebugHooks {
    static weak var dragMonitor: DragMonitor?
}

private struct DebugFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    func debugFrame(_ name: String) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: DebugFrameKey.self, value: [name: proxy.frame(in: .global)])
        })
    }

    // on a window's root view: collects the named frames inside it
    func debugFrameRoot(_ root: String) -> some View {
        onPreferenceChange(DebugFrameKey.self) { frames in
            MainActor.assumeIsolated {
                DebugFrames.roots[root] = frames
            }
        }
    }
}
#else
extension View {
    func debugFrame(_ name: String) -> some View {
        self
    }

    func debugFrameRoot(_ root: String) -> some View {
        self
    }
}
#endif
