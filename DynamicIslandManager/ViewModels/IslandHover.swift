import AppKit
import Combine

// hover and drag handling, mouse events in, expand and collapse out
// lives outside swiftui so drag monitor changes don't re-render the island
@MainActor
final class IslandHover {
    let model: IslandViewModel
    let dragMonitor: DragMonitor
    private weak var window: DynamicIslandWindow?
    private var hoverExitTask: Task<Void, Never>?
    private var proximityTimer: Timer?
    private var pointerMonitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var activePoll: Timer?               // only while this app is in front
    private var dragPoll: Timer?                 // only during a finder drag
    private var holds = false
    // where the pointer last was over the island, a still pointer keeps the keys when the island gets shorter under it
    private var keysPointer: NSPoint?
    // whether the last check wanted the keys, they're taken only when that starts
    private var wantedKeys = false
    private var cancellables = Set<AnyCancellable>()

    init(model: IslandViewModel, dragMonitor: DragMonitor, window: DynamicIslandWindow) {
        self.model = model
        self.dragMonitor = dragMonitor
        self.window = window
    }

    private var isExpanded: Bool {
        model.currentState == .expanded
    }

    // where the mouse is (debug scenarios can stand in for it)
    private var mouseLocation: NSPoint {
        #if DEBUG
        if let location = DebugPointer.override {
            return location
        }
        #endif
        return NSEvent.mouseLocation
    }

    // mouse y counts from 1, NSMouseInRect keeps the screen's top row inside
    private var pointerOverIsland: Bool {
        guard let window else { return false }
        return NSMouseInRect(mouseLocation, window.islandFrame, false)
    }

    func start() {
        print("island started")
        model.pointerIsOverIsland = { [weak self] in
            self?.pointerOverIsland ?? false
        }
        #if DEBUG
        DebugHooks.dragMonitor = dragMonitor
        observers.append(NotificationCenter.default.addObserver(forName: .debugPointerMoved, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hoverTick()
            }
        })
        #endif
        // the window takes clicks only while open, and only over the island
        model.$currentState
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self else { return }
                self.window?.pointer = self.mouseLocation
                self.window?.isExpanded = state == .expanded
            }
            .store(in: &cancellables)
        // after the change, like swiftui's onChange, so both drag flags are set
        dragMonitor.$isDraggingFiles
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] dragging in
                MainActor.assumeIsolated {
                    self?.fileDragChanged(dragging)
                }
            }
            .store(in: &cancellables)
        dragMonitor.$isDraggingAnything
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] dragging in
                MainActor.assumeIsolated {
                    self?.anyDragChanged(dragging)
                }
            }
            .store(in: &cancellables)
        // a status or card let go of the island while the pointer was already outside
        model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.holdMayHaveChanged()
                }
            }
            .store(in: &cancellables)
        holds = model.holdsExpanded
        dragMonitor.startMonitoring()
        startHoverMonitoring()
    }

    func stop() {
        dragMonitor.stopMonitoring()
        proximityTimer?.invalidate()
        proximityTimer = nil
        for monitor in pointerMonitors {
            NSEvent.removeMonitor(monitor)
        }
        pointerMonitors = []
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        stopActivePoll()
        stopDragPoll()
        cancellables = []
    }

    // MARK: hover

    // hover uses mouse events instead of a timer, global monitor for other apps
    // (needs no permission for mouse events), local one for this app's windows
    private func startHoverMonitoring() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .mouseExited]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated {
                #if DEBUG
                DebugHooks.noteGlobalMouseEvent()
                #endif
                self?.hoverTick()
            }
        }) {
            pointerMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated {
                self?.hoverTick()
            }
            return event
        }) {
            pointerMonitors.append(local)
        }
        // with this app in front, moving over its menu bar to the notch sends no event
        // either monitor sees, so poll only then
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.startActivePoll()
            }
        })
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stopActivePoll()
            }
        })
        if NSApp.isActive {
            startActivePoll()
        }
    }

    private func startActivePoll() {
        guard activePoll == nil else { return }
        activePoll = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hoverTick()
            }
        }
        activePoll?.tolerance = 0.05
    }

    private func stopActivePoll() {
        activePoll?.invalidate()
        activePoll = nil
    }

    private func hoverTick() {
        guard let window else { return }
        let location = mouseLocation
        // drags too, a drop below a short island goes to the app underneath
        window.pointer = location
        guard !dragMonitor.isDraggingAnything else { return }
        let inPill = NSMouseInRect(location, window.pillFrame, false)
        let inIsland = NSMouseInRect(location, window.islandFrame, false)
        if !isExpanded && inPill {
            model.expand()
        } else if isExpanded && !inIsland && !dragMonitor.isDraggingFiles {
            // start collapse timer
            if hoverExitTask == nil {
                scheduleCollapse()
            }
        } else if isExpanded && inIsland {
            // cancel timer
            hoverExitTask?.cancel()
            hoverExitTask = nil
            model.pointerArrived()
        }
        updateKey()
    }

    // keys go to the island only while the pointer is over something it can act on, or hasn't moved since
    var wantsKeys: Bool {
        isExpanded && model.wantsKeys && (pointerOverIsland || mouseLocation == keysPointer)
    }

    // nothing to type at during a finder drag
    // not taken again on every tick, keys moved to another app with the keyboard stay there
    private func updateKey() {
        guard let window, !window.isDragging else { return }
        if pointerOverIsland {
            keysPointer = mouseLocation
        } else if !isExpanded {
            keysPointer = nil
        }
        let wants = wantsKeys
        defer { wantedKeys = wants }
        if wants && !wantedKeys && !window.isKeyWindow {
            window.makeKey()
        } else if !wants {
            window.giveBackKey()
        }
    }

    // the normal 0.3 s collapse, always replacing the previous one
    private func scheduleCollapse() {
        hoverExitTask?.cancel()
        hoverExitTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(DesignConstants.hoverExitDelay))
            guard let self, !Task.isCancelled else { return }
            if self.isExpanded && !self.dragMonitor.isDraggingAnything {
                self.model.collapse()
            }
            self.hoverExitTask = nil
        }
    }

    private func holdMayHaveChanged() {
        // judged against the island the user saw, the window still has its old hit area
        let wasOver = window.map { !$0.ignoresMouseEvents } ?? false
        // the island may have changed height under a still pointer
        window?.pointer = mouseLocation
        let now = model.holdsExpanded
        defer {
            holds = now
            updateKey()
        }
        if holds && !now && isExpanded && !wasOver {
            scheduleCollapse()
        }
    }

    // MARK: drags

    private func fileDragChanged(_ dragging: Bool) {
        model.fileDragChanged(dragging, urls: dragMonitor.draggedURLs)
        if dragging {
            hoverExitTask?.cancel()
            hoverExitTask = nil
            model.expand(fromDrag: true)
            window?.isExpanded = true
            window?.isDragging = true
            startDragPoll()
        } else {
            stopDragPoll()
            window?.isDragging = false
            if !pointerOverIsland {
                scheduleCollapse()
            }
        }
    }

    // mouse events may not reach us mid-drag, so the pointer is polled for the drop area
    // the island takes the drop over itself, below it the drop goes to the app underneath
    private func startDragPoll() {
        guard dragPoll == nil else { return }
        window?.pointer = mouseLocation
        dragPoll = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.window?.pointer = self.mouseLocation
            }
        }
        dragPoll?.tolerance = 0.01
    }

    private func stopDragPoll() {
        dragPoll?.invalidate()
        dragPoll = nil
    }

    // drags that aren't files open the island only near the notch
    private func anyDragChanged(_ dragging: Bool) {
        if dragging && !dragMonitor.isDraggingFiles {
            proximityTimer?.invalidate()
            proximityTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self, self.dragMonitor.isDraggingAnything else {
                        timer.invalidate()
                        self?.proximityTimer = nil
                        return
                    }
                    guard let window = self.window else { return }
                    let near = window.pillFrame.insetBy(dx: -50, dy: -50).contains(self.mouseLocation)
                    if near && !self.isExpanded {
                        self.model.expand(fromDrag: true)
                    } else if !near && self.isExpanded {
                        self.model.collapse()
                    }
                }
            }
        } else if !dragging {
            // drag ended cleanup
            proximityTimer?.invalidate()
            proximityTimer = nil
            if isExpanded && !dragMonitor.isDraggingFiles {
                scheduleCollapse()
            }
        }
    }
}
