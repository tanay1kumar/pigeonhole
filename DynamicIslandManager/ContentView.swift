import SwiftUI

struct ContentView: View {
    // owned by the app delegate, so there's only ever one
    var islandViewModel = IslandViewModel()

    var body: some View {
        IslandView(viewModel: islandViewModel)
            .padding(DesignConstants.windowPadding / 2)
    }
}

#Preview {
    ContentView()
}
