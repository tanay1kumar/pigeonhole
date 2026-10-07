import SwiftUI

struct SignInView: View {
    @ObservedObject var driveViewModel: DriveViewModel
    // the titled window google's sign-in attaches to
    let presentingWindow: () -> NSWindow?

    var body: some View {
        VStack(spacing: 24) {
            // app icon
            VStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)

                Text("Dynamic Island")
                    .font(.system(size: 24, weight: .bold))

                Text("Sign in to use Google Drive")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 40)

            Spacer()

            if let error = driveViewModel.signInError {
                // orange text is about 2:1 in light mode, only the icon keeps the color
                Label {
                    Text(error)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 40)
            }

            // signin button
            Button(action: {
                guard let window = presentingWindow() else { return }
                Task {
                    await driveViewModel.signIn(presenting: window)
                }
            }) {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 18))
                        .accessibilityHidden(true)
                    Text("Sign in with Google")
                        .font(.system(size: 16, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.accentColor)
                .foregroundStyle(.white)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .padding(.horizontal, 40)
            .padding(.bottom, 40)
        }
        .frame(width: 400, height: 350)
    }
}
