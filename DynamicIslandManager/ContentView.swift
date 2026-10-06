import SwiftUI

struct ContentView: View {
    // owned by the app delegate so there's only one
    var islandViewModel = IslandViewModel()

    var body: some View {
        IslandView(viewModel: islandViewModel)
            .padding(DesignConstants.windowPadding / 2)
            .debugFrameRoot("island")
    }
}

#Preview {
    ContentView()
}
