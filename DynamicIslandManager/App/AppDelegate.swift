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
    var settingsWindow: SettingsWindow?
    private var destinationsPane: NSHostingController<AnyView>?
    // the app has no dock icon, this is its way in
    private(set) var menuBarItem: MenuBarItem?
    private var keyMonitor: Any?
    // lazy so cli modes don't touch google sign-in
    lazy var driveViewModel = DriveViewModel()
    let destinationStore = AppDelegate.makeDestinationStore()
    private(set) var islandViewModel: IslandViewModel?
    private(set) var islandHover: IslandHover?
    // learned data, real app only
    private(set) var learningStore: LearningStore?
    private(set) var classifier: DestinationClassifier?
    // what was sent and drive's quota, real app only
    private(set) var activityStore: ActivityStore?
    private(set) var storageStatus: StorageStatus?
    private(set) var conversion = ConversionService()
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
        menuBarItem = MenuBarItem(onSettings: { [weak self] in
            self?.showSettings(nil)
        }, onActivity: { [weak self] in
            self?.islandViewModel?.showFromMenu(.activity)
        }, canShowActivity: { [weak self] in
            // signed out the island is hidden, there's nothing to open
            self?.driveViewModel.driveService.isSignedIn ?? false
        })

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

        var activityURL = ActivityStore.defaultURL
        var storageDefaults: UserDefaults? = .standard
        #if DEBUG
        // scenarios keep activity in a temp file and the quota in their scratch domain
        if let scenarioURL = DebugScenarios.activityFileURL {
            activityURL = scenarioURL
            storageDefaults = DebugScenarios.scratchDefaults
        }
        #endif
        activityStore = ActivityStore(fileURL: activityURL)
        // converted copies left from last time
        var conversionRoot = ConversionService.defaultRoot
        #if DEBUG
        if DebugScenarios.isScenarioRun {
            conversionRoot = URL(fileURLWithPath: NSTemporaryDirectory() + "dim-scn/convert", isDirectory: true)
        }
        #endif
        conversion = ConversionService(root: conversionRoot)
        conversion.removeTemporaryFiles()
        let driveService = driveViewModel.driveService
        storageStatus = StorageStatus(defaults: storageDefaults) { try await driveService.about() }
        watchRemovedDestinations()

        // listen for sign-in changes, also fires after signing in again
        driveViewModel.driveService.$isSignedIn
            .sink { [weak self] isSignedIn in
                if isSignedIn {
                    self?.signInWindow?.close()
                    self?.signInWindow = nil
                    // empty only after a sign out, the new account's quota comes now
                    if self?.storageStatus?.about == nil {
                        self?.storageStatus?.refreshIfOld()
                    }
                    self?.showDynamicIsland()
                    Task { await self?.refreshDestinationNames() }
                    NotificationCenter.default.post(name: .didSignIn, object: nil)
                }
            }
            .store(in: &cancellables)

        // the island asks for settings, or for its destinations pane
        NotificationCenter.default.publisher(for: .showDestinationSetup)
            .sink { [weak self] _ in
                self?.showSettings(.destinations)
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .showSettings)
            .sink { [weak self] _ in
                self?.showSettings(nil)
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
        // sign-in can fire again later, only make one island, a sign out hid it
        guard window == nil else {
            if window?.isVisible == false {
                window?.orderFrontRegardless()
                islandHover?.start()
            }
            logIslandCount()
            return
        }

        let island = DynamicIslandWindow()
        window = island

        let viewModel = IslandViewModel(driveService: driveViewModel.driveService,
                                        destinationStore: destinationStore,
                                        classifier: classifier ?? DestinationClassifier(store: LearningStore(fileURL: nil)),
                                        extractor: extractor,
                                        activity: activityStore,
                                        storage: storageStatus)
        islandViewModel = viewModel
        viewModel.conversion = conversion
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
        // keys reach the island only while it's key, hover decides when that is
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let used = MainActor.assumeIsolated { self?.useKey(event) ?? false }
            return used ? nil : event
        }
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
            showSettings(.destinations)
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

    // a key while the island is key, true when it's used or must go no further
    private func useKey(_ event: NSEvent) -> Bool {
        guard let island = window, event.window === island, let model = islandViewModel else { return false }
        guard let key = IslandKey(event) else {
            // the menu bar belongs to the app in front, its quit and hide must not land on this one
            // NSApp.isActive reads true while the panel borrows the keys, the running app's flag doesn't
            return IslandKey.swallowsAppMenuKey(event, thisAppInFront: NSRunningApplication.current.isActive)
        }
        // a held key repeats into whatever the first press opened, and with the pointer gone the keys aren't the island's
        // both are eaten, the card's own return shortcut would take them otherwise
        if event.isARepeat || islandHover?.wantsKeys != true {
            return key != .settings
        }
        guard let action = model.keyAction(for: key) else { return false }
        print("key: \(key) did \(action)")
        model.perform(action)
        return true
    }

    // nil opens on the pane used last
    func showSettings(_ pane: SettingsPane?) {
        if settingsWindow == nil {
            // a root each, panes laid out later would replace each other's frames
            let general = GeneralPane(activity: activityStore ?? ActivityStore(fileURL: nil))
                .debugFrameRoot("settings-general")
            let destinations = NSHostingController(rootView: makeDestinationsPane())
            destinationsPane = destinations
            let account = AccountPane(driveService: driveViewModel.driveService,
                                      storage: storageStatus ?? StorageStatus(defaults: nil) { throw DriveError.notSignedIn },
                                      onSignOut: { [weak self] in self?.signOut() })
                .debugFrameRoot("settings-account")
            settingsWindow = SettingsWindow(panes: [
                .general: NSHostingController(rootView: general),
                .destinations: destinations,
                .account: NSHostingController(rootView: account),
                .about: NSHostingController(rootView: AboutPane()),
            ])
        } else if settingsWindow?.isVisible != true {
            // each open starts from what's saved now, like the old window, learned counts included
            destinationsPane?.rootView = makeDestinationsPane()
        }
        if let pane {
            settingsWindow?.show(pane)
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // a new identity each time, so its model and rows start over
    private func makeDestinationsPane() -> AnyView {
        AnyView(DestinationSetupView(store: destinationStore, driveService: driveViewModel.driveService,
                                     classifier: classifier, learningStore: learningStore,
                                     onDone: { [weak self] in self?.settingsWindow?.close() })
            .id(UUID())
            .debugFrameRoot("destinations"))
    }

    // account's sign out, the island hides until someone signs in again
    private func signOut() {
        #if DEBUG
        // a stray click in a check must never end the user's real google session
        if DebugScenarios.isScenarioRun {
            print("sign out: skipped in a scenario run")
            return
        }
        #endif
        settingsWindow?.close()
        islandViewModel?.clearCard()
        islandHover?.stop()
        window?.orderOut(nil)
        driveViewModel.signOut()
        // the next account mustn't see this one's name or quota
        storageStatus?.reset()
        print("signed out, showing sign-in")
        showSignInWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false // keep running
    }

    // sync, not in a Task, the app is about to quit
    func applicationWillTerminate(_ notification: Notification) {
        learningStore?.flush()
        activityStore?.flush()
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
