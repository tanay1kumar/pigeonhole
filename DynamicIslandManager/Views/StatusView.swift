import SwiftUI

// a result below the notch
struct StatusView: View {
    let status: IslandStatus

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                // a white mark on the color, hierarchical tinting can come out grey
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .green)
                .font(.system(size: 24, weight: .medium))
                .frame(height: 26)

            Text(status.message)
                .font(.system(size: 13, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.tail)
            if !status.reveal.isEmpty {
                Button("Show in Finder") {
                    LinkActions.reveal(status.reveal)
                }
                .buttonStyle(SecondaryButtonStyle())
                .debugFrame("showInFinder")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.top, DesignConstants.notchBand)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    StatusView(status: IslandStatus(kind: .success, message: "Uploaded to My Drive"))
        .frame(width: DesignConstants.expandedWidth, height: DesignConstants.statusHeight)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
}
