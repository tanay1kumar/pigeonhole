import SwiftUI

// upload progress, results and the sign-in banner below the notch
struct StatusView: View {
    let status: IslandStatus
    let onSignIn: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            icon
                .font(.system(size: 30, weight: .medium))
                .frame(height: 34)

            Text(status.message)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.tail)

            if status.kind == .signIn {
                Button("Sign in again", action: onSignIn)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .debugFrame("signInAgain")
            }
        }
        .padding(.horizontal, 20)
        .frame(width: 340, height: 196)
        .padding(.top, 40)    // clear of the notch
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var icon: some View {
        switch status.kind {
        case .working:
            ProgressView()
                .controlSize(.regular)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failure:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .signIn:
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(.orange)
        }
    }
}

#Preview {
    StatusView(status: IslandStatus(kind: .signIn, message: "Signed out of Google Drive"), onSignIn: {})
        .frame(width: 380, height: 256)
        .background(Color.black)
}
