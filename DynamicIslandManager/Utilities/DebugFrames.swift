import SwiftUI
import AppKit

// debug builds remember where named controls are, so scenarios can click the real buttons.
// release builds compile .debugFrame away to nothing.
#if DEBUG
@MainActor
enum DebugFrames {
    // swiftui global space: top-left origin of the window's content view
    static var frames: [String: CGRect] = [:]
}

// scenarios can stand in for the mouse without moving the real cursor
@MainActor
enum DebugPointer {
    static var override: NSPoint?
}

extension View {
    func debugFrame(_ name: String) -> some View {
        background(GeometryReader { proxy in
            Color.clear
                .onAppear { DebugFrames.frames[name] = proxy.frame(in: .global) }
                .onChange(of: proxy.frame(in: .global)) { _, frame in DebugFrames.frames[name] = frame }
                .onDisappear { DebugFrames.frames[name] = nil }
        })
    }
}
#else
extension View {
    func debugFrame(_ name: String) -> some View {
        self
    }
}
#endif
