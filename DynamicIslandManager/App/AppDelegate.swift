import Cocoa
import SwiftUI
import Combine

// custom hosting view for drag/drop
class DragAwareHostingView<Content: View>: NSHostingView<Content> {
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: DynamicIslandWindow?
    var signInWindow: SignInWindow?
    var destinationsWindow: DestinationsWindow?
    var driveViewModel = DriveViewModel()
    let destinationStore = DestinationStore()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("app launched")

        // listen for sign-in changes
        driveViewModel.driveService.$isSignedIn
            .sink { [weak self] isSignedIn in
                if isSignedIn {
                    self?.signInWindow?.close()
                    self?.signInWindow = nil
                    self?.showDynamicIsland()
                }
            }
            .store(in: &cancellables)

        // island asks for the setup window
        NotificationCenter.default.publisher(for: .showDestinationSetup)
            .sink { [weak self] _ in
                self?.showDestinationSetup()
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
        signInWindow = SignInWindow(driveViewModel: driveViewModel)
        signInWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showDynamicIsland() {
        window = DynamicIslandWindow()

        let contentView = ContentView()
            .environmentObject(driveViewModel)
        let hostingView = DragAwareHostingView(rootView: contentView)

        // register for file drops
        hostingView.registerForDraggedTypes([.fileURL, .string])

        window?.contentView = hostingView
        window?.orderFrontRegardless()

        // first run, ask where files should go
        if destinationStore.destinations.isEmpty
            && !UserDefaults.standard.bool(forKey: "didShowDestinationSetup") {
            UserDefaults.standard.set(true, forKey: "didShowDestinationSetup")
            showDestinationSetup()
        }
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
}
