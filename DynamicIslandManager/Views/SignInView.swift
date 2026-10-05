import SwiftUI

struct SignInView: View {
    @ObservedObject var driveViewModel: DriveViewModel
    // the titled window google's sign-in attaches to
    let presentingWindow: () -> NSWindow?

    var body: some View {
        VStack(spacing: 24) {
            // app icon
            VStack(spacing: 12) {
                Image(systemName: "externaldrive.fill.badge.icloud")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue)

                Text("Dynamic Island Manager")
                    .font(.system(size: 24, weight: .bold))

                Text("Sign in with Google Drive to get started")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 40)

            Spacer()

            if let error = driveViewModel.signInError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
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
                    Text("Sign in with Google")
                        .font(.system(size: 16, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.blue)
                .foregroundStyle(.white)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 40)
            .padding(.bottom, 40)
        }
        .frame(width: 400, height: 350)
    }
}
