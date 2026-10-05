import SwiftUI
import UniformTypeIdentifiers

struct IslandView: View {
    let driveService: GoogleDriveService
    @StateObject private var viewModel: IslandViewModel
    @StateObject private var dragMonitor = DragMonitor()

    init(driveService: GoogleDriveService) {
        self.driveService = driveService
        _viewModel = StateObject(wrappedValue: IslandViewModel(driveService: driveService))
    }
    @State private var hoverExitTask: Task<Void, Never>?
    @State private var proximityTimer: Timer?
    @State private var hoverTimer: Timer?
    @State private var hoverCheckCounter = 0
    @State private var lastDraggedCube: CubeType?
    @State private var dragStartTime: Date?
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
                            .opacity(dragMonitor.isDraggingFiles && isExpanded && isMouseOverExpandedArea ? 1 : 0)
                    )

                // content views
                CollapsedView(viewModel: viewModel)
                    .frame(height: currentHeight)
                    .opacity(isExpanded ? 0 : 1)

                ExpandedIslandView(viewModel: viewModel, isDraggingFiles: dragMonitor.isDraggingFiles)
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
            dragMonitor.startMonitoring()
            startHoverMonitoring()
        }
        .onDisappear {
            dragMonitor.stopMonitoring()
            proximityTimer?.invalidate()
            proximityTimer = nil
            hoverTimer?.invalidate()
            hoverTimer = nil
        }
        .onChange(of: isExpanded) { expanded in
            if let window = NSApp.windows.first(where: { $0 is DynamicIslandWindow }) as? DynamicIslandWindow {
                window.isExpanded = expanded
            }
        }
        .onChange(of: dragMonitor.isDraggingFiles) { isDragging in
            if isDragging {
                hoverExitTask?.cancel()
                viewModel.expand()

                if let window = NSApp.windows.first(where: { $0 is DynamicIslandWindow }) as? DynamicIslandWindow {
                    window.isExpanded = true
                    window.isDragging = true
                }
            } else {
                if let window = NSApp.windows.first(where: { $0 is DynamicIslandWindow }) as? DynamicIslandWindow {
                    window.isDragging = false

                    let expandedFrame = window.getExpandedNotchFrame()
                    let mouseLocation = NSEvent.mouseLocation
                    let isInExpandedArea = expandedFrame.contains(mouseLocation)

                    if !isInExpandedArea {
                        hoverExitTask?.cancel()
                        hoverExitTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: UInt64(DesignConstants.hoverExitDelay * 1_000_000_000))
                            if !Task.isCancelled && isExpanded {
                                viewModel.collapse()
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: dragMonitor.isDraggingAnything) { isDragging in
            if isDragging && !dragMonitor.isDraggingFiles {
                proximityTimer?.invalidate()
                proximityTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [self] timer in
                    guard dragMonitor.isDraggingAnything else {
                        timer.invalidate()
                        proximityTimer = nil
                        return
                    }

                    if let window = NSApp.windows.first(where: { $0 is DynamicIslandWindow }) as? DynamicIslandWindow {
                        let collapsedNotchFrame = window.getCollapsedNotchFrame()
                        let isNearNotch = dragMonitor.isCursorNearNotch(notchFrame: collapsedNotchFrame)

                        if isNearNotch && !isExpanded {
                            viewModel.expand()
                        } else if !isNearNotch && isExpanded {
                            viewModel.collapse()
                        }
                    }
                }
            } else if !isDragging {
                // drag ended cleanup
                proximityTimer?.invalidate()
                proximityTimer = nil
                if isExpanded && !dragMonitor.isDraggingFiles {
                    // collapse after drag ends
                    hoverExitTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: UInt64(DesignConstants.hoverExitDelay * 1_000_000_000))
                        if !Task.isCancelled && isExpanded {
                            viewModel.collapse()
                        }
                    }
                }
            }
        }
    }

    private func startHoverMonitoring() {
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            // cleanup stuck cube drag state
            if let draggedCube = self.viewModel.draggedCube {
                // only check if not dragging
                if !self.dragMonitor.isDraggingAnything {
                    if self.lastDraggedCube == draggedCube {
                        // drag ended cleanup
                        if let startTime = self.dragStartTime, Date().timeIntervalSince(startTime) > 0.3 {
                            self.viewModel.draggedCube = nil
                            self.lastDraggedCube = nil
                            self.dragStartTime = nil
                        }
                    } else {
                        // new stuck drag
                        self.lastDraggedCube = draggedCube
                        self.dragStartTime = Date()
                    }
                }
            } else {
                // no drag active
                self.lastDraggedCube = nil
                self.dragStartTime = nil
            }

            // get frames from window
            if let window = NSApp.windows.first(where: { $0 is DynamicIslandWindow }) as? DynamicIslandWindow {
                let collapsedFrame = window.getCollapsedNotchFrame()
                let expandedFrame = window.getExpandedNotchFrame()
                let mouseLocation = NSEvent.mouseLocation

                // check mouse area
                let isInPill = collapsedFrame.contains(mouseLocation)
                let isInExpandedArea = expandedFrame.contains(mouseLocation)

                // update mouse state
                self.isMouseOverExpandedArea = isInExpandedArea

                // skip if dragging
                guard !self.dragMonitor.isDraggingAnything else { return }

                self.hoverCheckCounter += 1

                if !self.isExpanded && isInPill {
                    // expand
                    self.viewModel.expand()
                } else if self.isExpanded && !isInExpandedArea && !self.dragMonitor.isDraggingFiles {
                    // start collapse timer
                    if self.hoverExitTask == nil {
                        self.hoverExitTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: UInt64(DesignConstants.hoverExitDelay * 1_000_000_000))
                            if !Task.isCancelled && self.isExpanded && !self.dragMonitor.isDraggingAnything {
                                self.viewModel.collapse()
                                self.hoverExitTask = nil
                            }
                        }
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
    }

    private func handleHover(_ hovering: Bool) {
        // handled by timer now
    }
}

struct ExpandedIslandView: View {
    @ObservedObject var viewModel: IslandViewModel
    let isDraggingFiles: Bool

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
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                handleFileDrop(providers: providers)
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
            Task {
                let files = viewModel.droppedFiles

                // zip multiple files first
                if files.count > 1 {
                    print("zipping \(files.count) files...")
                    await MainActor.run {
                        viewModel.uploadStatus = "Zipping \(files.count) files..."
                    }

                    do {
                        let zipURL = try ZipUtility.zipFiles(files)
                        let zipFileItem = FileItem(url: zipURL)
                        await viewModel.uploadFile(zipFileItem)
                        ZipUtility.cleanupTempFile(at: zipURL)
                    } catch {
                        await viewModel.showNotificationMessage("Failed to zip files: \(error.localizedDescription)", type: .error)
                        await MainActor.run {
                            viewModel.uploadStatus = nil
                        }
                    }
                } else {
                    // single file upload
                    for file in files {
                        await viewModel.uploadFile(file)
                    }
                }

                await MainActor.run {
                    viewModel.clearFiles()
                }
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
    IslandView(driveService: GoogleDriveService())
        .background(Color.gray)
}
