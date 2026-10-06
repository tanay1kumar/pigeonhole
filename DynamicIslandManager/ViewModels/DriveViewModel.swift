import Foundation
import AppKit
import GoogleSignIn

class DriveViewModel: ObservableObject {
    @Published var driveService = GoogleDriveService()
    @Published var signInError: String?

    @MainActor
    func signIn(presenting window: NSWindow) async {
        signInError = nil
        do {
            try await driveService.signIn(presenting: window)
        } catch {
            print("Sign-in error: \(error.localizedDescription)")
            signInError = Self.message(for: error)
        }
    }

    // nil when there's nothing to say
    static func message(for error: Error) -> String? {
        // closing google's sheet isn't an error (appauth uses -5 too, check the domain)
        if let gidError = error as? GIDSignInError, gidError.code == .canceled {
            return nil
        }
        if let driveError = error as? DriveError {
            return driveError.message ?? driveError.shortText
        }
        return "Couldn't sign in. \(error.localizedDescription)"
    }

    func signOut() {
        driveService.signOut()
    }
}
