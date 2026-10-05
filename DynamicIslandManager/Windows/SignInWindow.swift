import SwiftUI
import AppKit

extension Notification.Name {
    // the island's "Sign in again" button
    static let showSignIn = Notification.Name("showSignIn")
    // posted every time sign-in succeeds, clears the island's banner
    static let didSignIn = Notification.Name("didSignIn")
}

class SignInWindow: NSWindow {
    init(driveViewModel: DriveViewModel) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 350),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        self.title = "Sign In"
        self.isReleasedWhenClosed = false
        self.center()
        self.setFrameAutosaveName("SignInWindow")

        // window on all spaces
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // set content
        // google's sign-in sheet attaches to this window, not the borderless island
        self.contentView = NSHostingView(rootView: SignInView(
            driveViewModel: driveViewModel,
            presentingWindow: { [weak self] in self }
        ))
    }
}
