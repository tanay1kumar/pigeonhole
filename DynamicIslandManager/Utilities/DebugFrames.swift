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
    // hover runs on mouse events now: moving the stand-in pointer counts as one
    static var override: NSPoint? {
        didSet {
            NotificationCenter.default.post(name: .debugPointerMoved, object: nil)
        }
    }
}

extension Notification.Name {
    static let debugPointerMoved = Notification.Name("debugPointerMoved")
}

// what scenarios reach into that the views own
@MainActor
enum DebugHooks {
    static weak var dragMonitor: DragMonitor?
    // real mouse moves over other apps seen by hover's global monitor (the user's, never a script's)
    static var globalMouseEvents = 0

    // the plan §5 step 6 tcc check: launched with -preRead YES (an argument, nothing is saved), read the first
    // 4 KB of each dragged local file during the drag and log the outcome, never the name
    static func preRead(_ urls: [URL]) {
        guard UserDefaults.standard.bool(forKey: "preRead") else { return }
        for url in urls.prefix(5) {
            Task.detached(priority: .utility) {
                let ext = url.pathExtension.lowercased()
                let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey, .ubiquitousItemDownloadingStatusKey])
                if values?.volumeIsLocal == false || (values?.ubiquitousItemDownloadingStatus.map { $0 != .current } ?? false) {
                    print("pre-read \(ext) skipped (not a local file)")
                    return
                }
                do {
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    _ = try handle.read(upToCount: 4096)
                    print("pre-read \(ext) ok")
                } catch {
                    print("pre-read \(ext) \((error as NSError).domain) \((error as NSError).code)")
                }
            }
        }
    }

    static func noteGlobalMouseEvent() {
        globalMouseEvents += 1
        if globalMouseEvents == 1 || globalMouseEvents % 500 == 0 {
            print("hover: \(globalMouseEvents) global mouse event(s) seen")
        }
    }
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
