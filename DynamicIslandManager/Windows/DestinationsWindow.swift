import SwiftUI
import AppKit

extension Notification.Name {
    static let showDestinationSetup = Notification.Name("showDestinationSetup")
}

class DestinationsWindow: NSWindow {
    init(store: DestinationStore, driveService: GoogleDriveService) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        self.title = "Destinations"
        self.isReleasedWhenClosed = false
        self.center()

        // window on all spaces
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        self.contentView = NSHostingView(rootView: DestinationSetupView(
            store: store,
            driveService: driveService,
            onDone: { [weak self] in self?.close() }
        ))
    }
}
