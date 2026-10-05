import Cocoa
import SwiftUI
import Combine

// custom hosting view for drag/drop
class DragAwareHostingView<Content: View>: NSHostingView<Content> {
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var window: DynamicIslandWindow?
    var signInWindow: SignInWindow?
    var destinationsWindow: DestinationsWindow?
    // lazy so the cli modes never touch google sign-in
    lazy var driveViewModel = DriveViewModel()
    let destinationStore = DestinationStore()
    private(set) var islandViewModel: IslandViewModel?
    // learned data, only for the real app (cli modes never open the real file)
    private(set) var learningStore: LearningStore?
    private(set) var classifier: DestinationClassifier?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // print to a file or pipe is block-buffered otherwise, logs need lines right away
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

        let store = LearningStore(fileURL: LearningStore.defaultURL)
        learningStore = store
        classifier = DestinationClassifier(store: store)
        watchRemovedDestinations()

        // listen for sign-in changes, this fires again after a re-sign-in
        driveViewModel.driveService.$isSignedIn
            .sink { [weak self] isSignedIn in
                if isSignedIn {
                    self?.signInWindow?.close()
                    self?.signInWindow = nil
                    self?.showDynamicIsland()
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
        // sign-in can succeed again later (re-auth), there's only ever one island
        guard window == nil else {
            logIslandCount()
            return
        }

        window = DynamicIslandWindow()

        let viewModel = IslandViewModel(driveService: driveViewModel.driveService)
        islandViewModel = viewModel
        let hostingView = DragAwareHostingView(rootView: ContentView(islandViewModel: viewModel))

        // register for file drops
        hostingView.registerForDraggedTypes([.fileURL, .string])

        window?.contentView = hostingView
        window?.orderFrontRegardless()
        logIslandCount()

        // first run, ask where files should go
        if destinationStore.destinations.isEmpty
            && !UserDefaults.standard.bool(forKey: "didShowDestinationSetup") {
            UserDefaults.standard.set(true, forKey: "didShowDestinationSetup")
            showDestinationSetup()
        }

        #if DEBUG
        DebugScenarios.startIfRequested(app: self)
        #endif
    }

    private func logIslandCount() {
        print("island windows: \(NSApp.windows.filter { $0 is DynamicIslandWindow }.count)")
    }

    private func showDestinationSetup() {
        if destinationsWindow?.isVisible != true {
            destinationsWindow = DestinationsWindow(
                store: destinationStore,
                driveService: driveViewModel.driveService
            )
        }
        destinationsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false // keep running
    }

    // synchronous, never inside a Task: the process is about to end
    func applicationWillTerminate(_ notification: Notification) {
        learningStore?.flush()
    }

    // a removed destination takes what was learned about it along
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
