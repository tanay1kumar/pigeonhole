import AppKit
import Combine

class DragMonitor: ObservableObject {
    @Published var isDraggingFiles = false
    @Published var isDraggingAnything = false  // Track any drag (files or non-files)

    private var dragMonitor: Any?
    private var mouseUpMonitor: Any?
    private var mouseDownMonitor: Any?
    private var isCurrentlyDragging = false
    private var dragStartTime: Date?
    // the finder drag's files; urls only, and only with the debug pre-read switch
    private(set) var draggedURLs: [URL] = []

    static let readsDraggedFiles: Bool = {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "preRead")
        #else
        return false
        #endif
    }()

    // check if cursor near notch
    func isCursorNearNotch(notchFrame: NSRect) -> Bool {
        let mouseLocation = NSEvent.mouseLocation

        // expand frame by margin
        let expandedFrame = notchFrame.insetBy(dx: -50, dy: -50)

        return expandedFrame.contains(mouseLocation)
    }

    func startMonitoring() {
        print("🔍 Starting global drag monitoring...")

        // monitor mouse down
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self = self else { return }
            self.dragStartTime = Date()
            self.isCurrentlyDragging = false

            // reset state, only what's set: every publish redraws the island
            DispatchQueue.main.async {
                if self.isDraggingFiles {
                    self.isDraggingFiles = false
                }
                if self.isDraggingAnything {
                    self.isDraggingAnything = false
                }
            }

            // clear pasteboard
            let pasteboard = NSPasteboard(name: .drag)
            pasteboard.clearContents()
        }

        // monitor mouse dragged
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            guard let self = self else { return }

            // check once per drag
            guard !self.isCurrentlyDragging else { return }

            // check if drag moved enough
            if event.deltaX * event.deltaX + event.deltaY * event.deltaY > 25 {
                self.isCurrentlyDragging = true

                // check pasteboard types
                let pasteboard = NSPasteboard(name: .drag)
                let types = pasteboard.types ?? []

                // check if from finder
                let isFromFinder = types.contains(where: { type in
                    type.rawValue.contains("com.apple.finder") ||
                    type.rawValue == "NSFilenamesPboardType"
                })

                // a drag's file list is read only for the debug pre-read check: the app doesn't look at what's
                // being dragged until it's dropped here (reading it also logs a sandbox-extension failure)
                let urls = isFromFinder && Self.readsDraggedFiles
                    ? (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
                    : []
                print("🔍 Drag session started - isFromFinder: \(isFromFinder)" + (Self.readsDraggedFiles ? ", \(urls.count) file url(s) on the pasteboard" : ""))
                print("   Types: \(types.map { $0.rawValue })")

                DispatchQueue.main.async {
                    self.draggedURLs = urls
                    if self.isDraggingFiles != isFromFinder {
                        self.isDraggingFiles = isFromFinder
                    }
                    if !self.isDraggingAnything {
                        self.isDraggingAnything = true  // Track any drag
                    }
                    if isFromFinder {
                        print("✅ FINDER DRAG - expanding island")
                    } else {
                        print("❌ NON-FINDER DRAG - will expand on proximity")
                    }
                }
            }
        }

        // monitor mouse up
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.isDraggingFiles {
                    self.isDraggingFiles = false
                }
                if self.isDraggingAnything {
                    self.isDraggingAnything = false
                }
                self.isCurrentlyDragging = false
                self.dragStartTime = nil
            }
        }
    }

    func stopMonitoring() {
        print("🛑 Stopping global drag monitoring...")

        if let monitor = dragMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = mouseUpMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = mouseDownMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
