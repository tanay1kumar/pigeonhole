import SwiftUI

struct ContentView: View {
    // owned by the app delegate so there's only one
    var islandViewModel = IslandViewModel()

    var body: some View {
        // the window's top sits above the screen, the island starts at the screen's edge
        IslandView(viewModel: islandViewModel)
            .padding(.top, DesignConstants.topOverhang)
            .frame(width: DesignConstants.windowWidth, height: DesignConstants.windowHeight, alignment: .top)
            .debugFrameRoot("island")
    }
}

#Preview {
    ContentView()
}
