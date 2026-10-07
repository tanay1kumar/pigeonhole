import SwiftUI
import AppKit

// debug builds track named controls so scenarios can click the real buttons
// release builds compile .debugFrame away
#if DEBUG
@MainActor
enum DebugFrames {
    // per window root, what's laid out in it right now
    // a preference not onAppear/onDisappear, transitions left entries missing
    static var roots: [String: [String: CGRect]] = [:]
    // --no-debug-frames for timing runs, the frame readers cost time every frame
    nonisolated static let enabled = CommandLine.arguments.contains("--debug-scenario")
        && !CommandLine.arguments.contains("--no-debug-frames")

    // each root's own space, the top-left of the window content it fills
    // swiftui's global space moved with the toolbar for a pane laid out before the window had one, and never caught up
    nonisolated static let space = "debugFrameRoot"

    static var frames: [String: CGRect] {
        roots.values.reduce(into: [:]) { all, frames in
            all.merge(frames) { _, new in new }
        }
    }
}

// scenarios can stand in for the mouse without moving the real cursor
@MainActor
enum DebugPointer {
    // hover runs on mouse events, so moving the stand-in pointer counts as one
    static var override: NSPoint? {
        didSet {
            NotificationCenter.default.post(name: .debugPointerMoved, object: nil)
        }
    }
}

extension Notification.Name {
    static let debugPointerMoved = Notification.Name("debugPointerMoved")
}

// what scenarios reach into that hover owns
@MainActor
enum DebugHooks {
    static weak var dragMonitor: DragMonitor?
    // real mouse moves over other apps seen by hover's global monitor
    static var globalMouseEvents = 0

    // tcc check, with -preRead YES read 4 KB of each dragged file during the drag
    // and log the result (never the file name)
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
    // only scenario runs need positions, normal debug runs skip it
    @ViewBuilder
    func debugFrame(_ name: String) -> some View {
        if DebugFrames.enabled {
            background(GeometryReader { proxy in
                Color.clear.preference(key: DebugFrameKey.self, value: [name: proxy.frame(in: .named(DebugFrames.space))])
            })
        } else {
            self
        }
    }

    // goes on a window's root view, collects the named frames inside
    @ViewBuilder
    func debugFrameRoot(_ root: String) -> some View {
        if DebugFrames.enabled {
            coordinateSpace(name: DebugFrames.space)
                .onPreferenceChange(DebugFrameKey.self) { frames in
                    MainActor.assumeIsolated {
                        DebugFrames.roots[root] = frames
                    }
                }
        } else {
            self
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
