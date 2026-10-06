import Cocoa
import SwiftUI
import Combine

// custom hosting view for drag/drop
class DragAwareHostingView<Content: View>: NSHostingView<Content> {
    // so hover sees mouse moves over the island, it's never the key window
    private var pointerArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerArea {
            removeTrackingArea(pointerArea)
        }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerArea = area
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var window: DynamicIslandWindow?
    var signInWindow: SignInWindow?
    var destinationsWindow: DestinationsWindow?
    // lazy so cli modes don't touch google sign-in
    lazy var driveViewModel = DriveViewModel()
    let destinationStore = AppDelegate.makeDestinationStore()
    private(set) var islandViewModel: IslandViewModel?
    private(set) var islandHover: IslandHover?
    // learned data, real app only
    private(set) var learningStore: LearningStore?
    private(set) var classifier: DestinationClassifier?
    let extractor = FeatureExtractor()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // line buffered so logs show up right away when piped
        setvbuf(stdout, nil, _IOLBF, 0)

        // command line modes (--debug-*, --test), no ui
        if let command = DebugCommand.parse(CommandLine.arguments) {
            NSApp.setActivationPolicy(.prohibited)
            Task {
                exit(await command.run(drive: { self.driveViewModel.driveService }, store: destinationStore))
            }
            return
        }

        print("app launched")

        var learningURL = LearningStore.defaultURL
        #if DEBUG
        // scenarios use a temp learning file
        if let scenarioURL = DebugScenarios.learningFileURL {
            learningURL = scenarioURL
        }
        #endif
        let store = LearningStore(fileURL: learningURL)
        learningStore = store
        classifier = DestinationClassifier(store: store)
        watchRemovedDestinations()

        // listen for sign-in changes, also fires after signing in again
        driveViewModel.driveService.$isSignedIn
            .sink { [weak self] isSignedIn in
                if isSignedIn {
                    self?.signInWindow?.close()
                    self?.signInWindow = nil
                    self?.showDynamicIsland()
                    Task { await self?.refreshDestinationNames() }
                    NotificationCenter.default.post(name: .didSignIn, object: nil)
                }
            }
            .store(in: &cancellables)

        // island asks for the setup window
        NotificationCenter.default.publisher(for: .showDestinationSetup)
            .sink { [weak self] _ in
                self?.showDestinationSetup()
            }
            .store(in: &cancellables)

        // island's "Sign in again"
        NotificationCenter.default.publisher(for: .showSignIn)
            .sink { [weak self] _ in
                self?.showSignInWindow()
            }
            .store(in: &cancellables)

        // try restoring previous session
        Task {
            do {
                try await driveViewModel.driveService.restorePreviousSignIn()
                print("restored previous session")
            } catch {
                print("no previous session, showing sign-in")
                await MainActor.run {
                    showSignInWindow()
                }
            }
        }
    }

    private func showSignInWindow() {
        if signInWindow == nil {
            signInWindow = SignInWindow(driveViewModel: driveViewModel)
        }
        signInWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showDynamicIsland() {
        // sign-in can fire again later, only make one island
        guard window == nil else {
            logIslandCount()
            return
        }

        let island = DynamicIslandWindow()
        window = island

        let viewModel = IslandViewModel(driveService: driveViewModel.driveService,
                                        destinationStore: destinationStore,
                                        classifier: classifier ?? DestinationClassifier(store: LearningStore(fileURL: nil)),
                                        extractor: extractor)
        islandViewModel = viewModel
        // the window knows the screen, the view model draws the notch from it
        viewModel.islandScreen = island.islandScreen
        island.onScreenChange = { [weak viewModel] screen in
            viewModel?.islandScreen = screen
        }
        // hit-testing follows what's showing
        island.islandHeight = { [weak viewModel] in
            viewModel?.contentHeight ?? DesignConstants.expandedHeight
        }
        let hostingView = DragAwareHostingView(rootView: ContentView(islandViewModel: viewModel))

        // fixed size window, skips size updates on every layout
        hostingView.sizingOptions = []

        // register for file drops
        hostingView.registerForDraggedTypes([.fileURL])

        island.contentView = hostingView
        island.orderFrontRegardless()
        // hover and drags drive the island from outside swiftui
        let hover = IslandHover(model: viewModel, dragMonitor: DragMonitor(), window: island)
        islandHover = hover
        hover.start()
        logIslandCount()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            logMemory("10 s after launch")
        }

        // first run, ask where files should go (not in scenario runs)
        if destinationStore.destinations.isEmpty && !Self.isScenarioRun
            && !UserDefaults.standard.bool(forKey: "didShowDestinationSetup") {
            UserDefaults.standard.set(true, forKey: "didShowDestinationSetup")
            showDestinationSetup()
        }

        #if DEBUG
        DebugScenarios.startIfRequested(app: self)
        #endif
    }

    // scenario runs save to a scratch copy, not the real list
    nonisolated private static func makeDestinationStore() -> DestinationStore {
        #if DEBUG
        if let scratch = DebugScenarios.prepareScratch() {
            return DestinationStore(defaults: scratch)
        }
        #endif
        return DestinationStore()
    }

    private static var isScenarioRun: Bool {
        #if DEBUG
        return DebugScenarios.isScenarioRun
        #else
        return false
        #endif
    }

    // pick up folder renames from drive
    private func refreshDestinationNames() async {
        let drive = driveViewModel.driveService
        let renamed = await destinationStore.refreshNames { id in
            try await drive.getFile(id: id, fields: "id,name").name
        }
        for change in renamed {
            print("destinations: renamed \(change)")
        }
    }

    private func logIslandCount() {
        print("island windows: \(NSApp.windows.filter { $0 is DynamicIslandWindow }.count)")
    }

    private func showDestinationSetup() {
        if destinationsWindow?.isVisible != true {
            destinationsWindow = DestinationsWindow(
                store: destinationStore,
                driveService: driveViewModel.driveService,
                classifier: classifier,
                learningStore: learningStore
            )
        }
        destinationsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false // keep running
    }

    // sync, not in a Task, the app is about to quit
    func applicationWillTerminate(_ notification: Notification) {
        learningStore?.flush()
    }

    // removing a destination drops what it learned
    private func watchRemovedDestinations() {
        var known = Set(destinationStore.destinations.map(\.id))
        destinationStore.$destinations
            .dropFirst()
            .sink { [weak self] destinations in
                let current = Set(destinations.map(\.id))
                let removed = known.subtracting(current)
                known = current
                guard let classifier = self?.classifier, !removed.isEmpty else { return }
                Task {
                    for id in removed.sorted() {
                        await classifier.removeData(for: id)
                        print("learning: dropped data for removed destination \(id)")
                    }
                }
            }
            .store(in: &cancellables)
    }
}
