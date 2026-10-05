import SwiftUI
import UniformTypeIdentifiers

struct IslandView: View {
    @StateObject private var viewModel: IslandViewModel
    @StateObject private var dragMonitor = DragMonitor()

    init(viewModel: IslandViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }
    @State private var hoverExitTask: Task<Void, Never>?
    @State private var proximityTimer: Timer?
    @State private var pointerMonitors: [Any] = []      // NSEvent monitors
    @State private var appObservers: [NSObjectProtocol] = []
    @State private var activePoll: Timer?               // only while this app is in front
    @State private var cubeDragWatch: Timer?            // only during a cube reorder
    @State private var isDropTargeted = false
    @State private var isMouseOverExpandedArea = false

    private var isExpanded: Bool {
        viewModel.currentState == .expanded || viewModel.currentState == .draggingFile
    }

    // animated dimensions
    private var currentWidth: CGFloat {
        isExpanded ? DesignConstants.expandedWidth : DesignConstants.collapsedWidth
    }

    private var currentHeight: CGFloat {
        isExpanded ? DesignConstants.expandedHeight : DesignConstants.collapsedHeight
    }

    private var currentCornerRadius: CGFloat {
        isExpanded ? DesignConstants.expandedCornerRadius : DesignConstants.collapsedCornerRadius
    }

    var body: some View {
        ZStack(alignment: .top) {
            // inner content
            ZStack {
                // render both backgrounds
                NotchShape(cornerRadius: currentCornerRadius)
                    .fill(Color(white: 0.0))
                    .frame(width: currentWidth, height: currentHeight)
                    .opacity(isExpanded ? 0 : 1)

                RoundedRectangle(cornerRadius: currentCornerRadius)
                    .fill(Color(white: 0.0))
                    .frame(width: currentWidth, height: currentHeight)
                    .opacity(isExpanded ? 1 : 0)
                    .overlay(
                        RoundedRectangle(cornerRadius: currentCornerRadius)
                            .stroke(Color.accentColor, lineWidth: 2)
                            .opacity(isDropTargeted && isExpanded ? 1 : 0)
                    )

                // content views
                CollapsedView(viewModel: viewModel)
                    .frame(height: currentHeight)
                    .opacity(isExpanded ? 0 : 1)

                ExpandedIslandView(viewModel: viewModel, isDraggingFiles: dragMonitor.isDraggingFiles, isDropTargeted: $isDropTargeted)
                    .frame(height: currentHeight)
                    .opacity(isExpanded ? 1 : 0)
            }
            .frame(width: currentWidth, height: currentHeight)
            .contentShape(Rectangle())
        }
        .frame(width: DesignConstants.expandedWidth, height: DesignConstants.expandedHeight, alignment: .top)
        .animation(AnimationConstants.spring, value: isExpanded)
        .onAppear {
            print("island started")
            #if DEBUG
            DebugHooks.dragMonitor = dragMonitor
            #endif
            viewModel.pointerIsOverIsland = {
                islandWindow?.islandFrame.contains(mouseLocation) ?? false
            }
            dragMonitor.startMonitoring()
            startHoverMonitoring()
        }
        .onDisappear {
            dragMonitor.stopMonitoring()
            proximityTimer?.invalidate()
            proximityTimer = nil
            stopHoverMonitoring()
        }
        // a cube reorder: watch for the mouse button coming up, then nothing to watch
        .onChange(of: viewModel.draggedCube) { _, cube in
            if cube != nil {
                startCubeDragWatch()
            }
        }
        .onChange(of: isExpanded) { expanded in
            if let window = NSApp.windows.first(where: { $0 is DynamicIslandWindow }) as? DynamicIslandWindow {
                window.isExpanded = expanded
            }
        }
        .onChange(of: dragMonitor.isDraggingFiles) { isDragging in
            viewModel.fileDragChanged(isDragging, urls: dragMonitor.draggedURLs)
            if isDragging {
                hoverExitTask?.cancel()
                hoverExitTask = nil
                viewModel.expand(fromDrag: true)

                if let window = NSApp.windows.first(where: { $0 is DynamicIslandWindow }) as? DynamicIslandWindow {
                    window.isExpanded = true
                    window.isDragging = true
                }
            } else {
                if let window = NSApp.windows.first(where: { $0 is DynamicIslandWindow }) as? DynamicIslandWindow {
                    window.isDragging = false

                    let expandedFrame = window.getExpandedNotchFrame()
                    let isInExpandedArea = expandedFrame.contains(mouseLocation)

                    if !isInExpandedArea {
                        scheduleCollapse()
                    }
                }
            }
        }
        .onChange(of: dragMonitor.isDraggingAnything) { isDragging in
            if isDragging && !dragMonitor.isDraggingFiles {
                proximityTimer?.invalidate()
                proximityTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [self] timer in
                    MainActor.assumeIsolated {
                        guard dragMonitor.isDraggingAnything else {
                            timer.invalidate()
                            proximityTimer = nil
                            return
                        }

                        if let window = NSApp.windows.first(where: { $0 is DynamicIslandWindow }) as? DynamicIslandWindow {
                            let collapsedNotchFrame = window.getCollapsedNotchFrame()
                            let isNearNotch = dragMonitor.isCursorNearNotch(notchFrame: collapsedNotchFrame)

                            if isNearNotch && !isExpanded {
                                viewModel.expand(fromDrag: true)
                            } else if !isNearNotch && isExpanded {
                                viewModel.collapse()
                            }
                        }
                    }
                }
            } else if !isDragging {
                // drag ended cleanup
                proximityTimer?.invalidate()
                proximityTimer = nil
                if isExpanded && !dragMonitor.isDraggingFiles {
                    // collapse after drag ends
                    scheduleCollapse()
                }
            }
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .debugPointerMoved)) { _ in
            hoverTick()
        }
        #endif
        // a status or card let go of the island while the pointer was already outside
        .onChange(of: viewModel.holdsExpanded) { _, holds in
            if !holds && isExpanded && !(islandWindow?.islandFrame.contains(mouseLocation) ?? false) {
                scheduleCollapse()
            }
        }
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

    private var islandWindow: DynamicIslandWindow? {
        NSApp.windows.first(where: { $0 is DynamicIslandWindow }) as? DynamicIslandWindow
    }

    // the normal 0.3 s collapse, always replacing the previous one
    private func scheduleCollapse() {
        hoverExitTask?.cancel()
        hoverExitTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(DesignConstants.hoverExitDelay * 1_000_000_000))
            if !Task.isCancelled && isExpanded && !dragMonitor.isDraggingAnything {
                viewModel.collapse()
            }
            if !Task.isCancelled {
                hoverExitTask = nil
            }
        }
    }

    // hover follows mouse events instead of a 0.1 s timer (the plan §4.8): the global monitor sees moves
    // over other apps (mouse monitors need no permission), the local one moves over this app's windows
    private func startHoverMonitoring() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .mouseExited]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { _ in
            MainActor.assumeIsolated {
                #if DEBUG
                DebugHooks.noteGlobalMouseEvent()
                #endif
                hoverTick()
            }
        }) {
            pointerMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            MainActor.assumeIsolated {
                hoverTick()
            }
            return event
        }) {
            pointerMonitors.append(local)
        }
        // with this app in front (setup or sign-in window), moving over its own menu bar to the notch
        // sends no mouse event either monitor sees, so poll then, and only then
        let center = NotificationCenter.default
        appObservers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                startActivePoll()
            }
        })
        appObservers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                stopActivePoll()
            }
        })
        if NSApp.isActive {
            startActivePoll()
        }
    }

    private func stopHoverMonitoring() {
        for monitor in pointerMonitors {
            NSEvent.removeMonitor(monitor)
        }
        pointerMonitors = []
        for observer in appObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        appObservers = []
        stopActivePoll()
        cubeDragWatch?.invalidate()
        cubeDragWatch = nil
    }

    private func startActivePoll() {
        guard activePoll == nil else { return }
        activePoll = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                hoverTick()
            }
        }
        activePoll?.tolerance = 0.05
    }

    private func stopActivePoll() {
        activePoll?.invalidate()
        activePoll = nil
    }

    // a cube dragged and let go somewhere that isn't a cube leaves draggedCube set: clear it 0.3 s after
    // the mouse button comes up. an appkit drag session swallows that mouse-up, so this checks the button
    private func startCubeDragWatch() {
        cubeDragWatch?.invalidate()
        var releasedAt: Date?
        cubeDragWatch = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard viewModel.draggedCube != nil else {
                    timer.invalidate()
                    cubeDragWatch = nil
                    return
                }
                if NSEvent.pressedMouseButtons & 1 != 0 {
                    releasedAt = nil
                } else if let released = releasedAt {
                    if Date().timeIntervalSince(released) > 0.3 {
                        viewModel.draggedCube = nil
                        timer.invalidate()
                        cubeDragWatch = nil
                    }
                } else {
                    releasedAt = Date()
                }
            }
        }
    }

    private func hoverTick() {
        // get frames from window
        if let window = NSApp.windows.first(where: { $0 is DynamicIslandWindow }) as? DynamicIslandWindow {
            let collapsedFrame = window.getCollapsedNotchFrame()
            let expandedFrame = window.getExpandedNotchFrame()

            // check mouse area
            let isInPill = collapsedFrame.contains(mouseLocation)
            let isInExpandedArea = expandedFrame.contains(mouseLocation)

            // update mouse state
            // writing @State commits a swiftui transaction even when the value is the same
            if self.isMouseOverExpandedArea != isInExpandedArea {
                self.isMouseOverExpandedArea = isInExpandedArea
            }

            // skip if dragging
            guard !self.dragMonitor.isDraggingAnything else { return }


            if !self.isExpanded && isInPill {
                // expand
                self.viewModel.expand()
            } else if self.isExpanded && !isInExpandedArea && !self.dragMonitor.isDraggingFiles {
                // start collapse timer
                if self.hoverExitTask == nil {
                    self.scheduleCollapse()
                }
            } else if self.isExpanded && isInExpandedArea {
                // cancel timer
                if self.hoverExitTask != nil {
                    self.hoverExitTask?.cancel()
                    self.hoverExitTask = nil
                }
            }
        }
    }

    private func handleHover(_ hovering: Bool) {
        // handled by timer now
    }
}

struct ExpandedIslandView: View {
    @ObservedObject var viewModel: IslandViewModel
    let isDraggingFiles: Bool
    @Binding var isDropTargeted: Bool

    // keep drop zone visible briefly
    @State private var showDropZone = false

    // grid columns
    private let columns = [
        GridItem(.fixed(DesignConstants.cubeSize), spacing: DesignConstants.cubeSpacing),
        GridItem(.fixed(DesignConstants.cubeSize), spacing: DesignConstants.cubeSpacing),
        GridItem(.fixed(DesignConstants.cubeSize), spacing: DesignConstants.cubeSpacing)
    ]

    var body: some View {
        mainContent
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: showDropZone)
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: viewModel.status)
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: viewModel.cardState)
            .onChange(of: isDraggingFiles) { dragging in
                if dragging {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        showDropZone = true
                    }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            showDropZone = false
                        }
                    }
                }
            }
    }

    @ViewBuilder
    private var mainContent: some View {
        if showDropZone {
            dropZoneView
        } else if viewModel.cardState != .idle {
            SuggestionCardView(model: viewModel)
                .transition(.scale(scale: 0.85).combined(with: .opacity))
        } else if let status = viewModel.status {
            StatusView(status: status, onSignIn: viewModel.requestSignIn)
                .transition(.scale(scale: 0.85).combined(with: .opacity))
        } else {
            gridView
        }
    }

    private var dropZoneView: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .overlay(DropHereView())
            .transition(.scale(scale: 0.85).combined(with: .opacity))
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                // "classifying" shows before any file has loaded
                viewModel.handleDrop(providers)
                return true
            }
    }

    private var gridView: some View {
        LazyVGrid(columns: columns, spacing: DesignConstants.cubeSpacing) {
            ForEach(viewModel.cubeOrder) { cubeType in
                CubeView(cubeType: cubeType, viewModel: viewModel)
            }
        }
        .padding(DesignConstants.islandPadding)
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }

    private func handleFileDrop(providers: [NSItemProvider]) -> Bool {
        print("file drop: \(providers.count) items")

        for (index, provider) in providers.enumerated() {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
                guard let data = data,
                      let path = String(data: data, encoding: .utf8),
                      let url = URL(string: path) else {
                    if let error = error {
                        print("error loading file \(index + 1): \(error.localizedDescription)")
                    }
                    return
                }

                let fileItem = FileItem(url: url)
                print("loaded: \(fileItem.name) (\(fileItem.formattedSize))")

                DispatchQueue.main.async {
                    viewModel.addFiles([fileItem])
                }
            }
        }

        return true
    }
}

struct DropHereView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 48, weight: .medium))
                .foregroundStyle(.primary)

            Text("Drop Files Here")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.primary)
        }
    }
}

struct CubeView: View {
    let cubeType: CubeType
    @ObservedObject var viewModel: IslandViewModel
    @State private var isHovered = false
    @State private var isDropTarget = false

    private var isDragging: Bool {
        viewModel.draggedCube == cubeType
    }

    // blue outline on hover
    private var hasAttachedFiles: Bool {
        !viewModel.droppedFiles.isEmpty
    }

    private var isActionCube: Bool {
        cubeType == .upload || cubeType == .convert
    }

    private var shouldShowActionFeedback: Bool {
        hasAttachedFiles && isActionCube && isHovered
    }

    private var isLocked: Bool {
        hasAttachedFiles && !isActionCube
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 16)  // 16pt corner radius - Control Center standard
            .fill(.ultraThinMaterial)
            .overlay {
                cubeContent
            }
            .frame(width: DesignConstants.cubeSize, height: DesignConstants.cubeSize)
            .scaleEffect(computedScale)
            .opacity(computedOpacity)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .opacity(shouldShowOutline ? 1 : 0)
            )
            .animation(.easeInOut(duration: 0.2), value: isHovered)
            .animation(.easeInOut(duration: 0.2), value: isDragging)
            .animation(.easeInOut(duration: 0.2), value: isDropTarget)
            .animation(.easeInOut(duration: 0.2), value: isLocked)
            .animation(.easeInOut(duration: 0.2), value: shouldShowOutline)
            .onHover { hovering in
                isHovered = hovering
            }
            .onDrag {
                viewModel.draggedCube = cubeType
                return NSItemProvider(object: cubeType.rawValue as NSString)
            }
            .onDrop(of: [.text], delegate: CubeDropDelegate(
                cubeType: cubeType,
                viewModel: viewModel,
                isDropTarget: $isDropTarget
            ))
            // tap to perform action
            .onTapGesture {
                handleCubeTap()
            }
            .debugFrame("cube-\(cubeType.rawValue)")
    }

    private var cubeContent: some View {
        VStack(spacing: 8) {
            // icon
            Image(systemName: cubeType.icon)
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(.primary)

            // label
            Text(cubeType.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
    }

    private var computedScale: CGFloat {
        if isDragging {
            return 0.9
        } else if isLocked {
            return 0.9
        } else if isDropTarget || isHovered {
            return 1.05
        } else {
            return 1.0
        }
    }

    private var computedOpacity: Double {
        if isDragging {
            return 0.5
        } else if isLocked {
            return 0.6
        } else {
            return 1.0
        }
    }

    private var shouldShowOutline: Bool {
        shouldShowActionFeedback
    }

    private func handleCubeTap() {
        // unlock cubes if needed
        if isLocked {
            viewModel.clearFiles()
            return
        }

        guard hasAttachedFiles else {
            if cubeType == .destinations {
                NotificationCenter.default.post(name: .showDestinationSetup, object: nil)
            }
            return
        }

        // run action
        switch cubeType {
        case .upload:
            print("upload tapped with \(viewModel.droppedFiles.count) files")
            // zips several files, keeps them queued if it fails
            Task {
                await viewModel.uploadDroppedFiles()
            }

        case .convert:
            print("convert tapped with \(viewModel.droppedFiles.count) files")
            for file in viewModel.droppedFiles {
                print("converting: \(file.name)")
            }
            viewModel.clearFiles()

        default:
            print("cube \(cubeType.title) doesn't support files")
        }
    }
}

struct CubeDropDelegate: DropDelegate {
    let cubeType: CubeType
    let viewModel: IslandViewModel
    @Binding var isDropTarget: Bool

    func validateDrop(info: DropInfo) -> Bool {
        // reject file drags only accept cubes
        guard !info.hasItemsConforming(to: [.fileURL]) else {
            return false
        }
        return info.hasItemsConforming(to: [.text])
    }

    func dropEntered(info: DropInfo) {
        isDropTarget = true
    }

    func dropExited(info: DropInfo) {
        isDropTarget = false
    }

    func performDrop(info: DropInfo) -> Bool {
        isDropTarget = false

        guard let itemProvider = info.itemProviders(for: [.text]).first else {
            viewModel.draggedCube = nil
            return false
        }

        itemProvider.loadItem(forTypeIdentifier: "public.text", options: nil) { (data, error) in
            guard let data = data as? Data,
                  let rawValue = String(data: data, encoding: .utf8),
                  let draggedCubeType = CubeType(rawValue: rawValue) else {
                DispatchQueue.main.async {
                    viewModel.draggedCube = nil
                }
                return
            }

            DispatchQueue.main.async {
                viewModel.reorderCube(from: draggedCubeType, to: cubeType)
            }
        }

        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .move)
    }
}

#Preview {
    IslandView(viewModel: IslandViewModel())
        .background(Color.gray)
}
