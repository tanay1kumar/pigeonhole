import SwiftUI
import UniformTypeIdentifiers

// the island, one shape that grows out of the notch
// content is only there while it's open, hover and drags live in IslandHover
struct IslandView: View {
    @ObservedObject var viewModel: IslandViewModel
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var isDropTargeted = false

    // the system setting can't be changed from code, scenarios use the model's switch
    private var reduceMotion: Bool {
        #if DEBUG
        if viewModel.debugReduceMotion {
            return true
        }
        #endif
        return systemReduceMotion
    }

    var body: some View {
        #if DEBUG
        let _ = BodyCounts.note("IslandView")
        #endif
        let metrics = viewModel.metrics
        let expanded = viewModel.isExpanded
        ZStack(alignment: .top) {
            IslandShape(metrics: metrics)
                .fill(Color.black)
            if viewModel.contentMounted {
                IslandContentView(viewModel: viewModel, isDropTargeted: $isDropTargeted)
                    .frame(width: DesignConstants.expandedWidth, height: metrics.height, alignment: .top)
                    .transition(contentTransition)
            }
            // drop highlight, the clip keeps the inner half of the line
            // it sits over the drop zone, so it must not take the drag
            IslandShape(metrics: metrics)
                .stroke(Color.accentColor, lineWidth: 3)
                .opacity(isDropTargeted && expanded ? 1 : 0)
                .allowsHitTesting(false)
        }
        .frame(width: DesignConstants.windowWidth, height: DesignConstants.expandedHeight, alignment: .top)
        .clipShape(IslandShape(metrics: metrics))
        // open and close win over the content-sized changes in between
        .animation(shapeAnimation(opening: expanded), value: expanded)
        .animation(reduceMotion ? Motion.close : Motion.content, value: metrics)
        .environment(\.islandReduceMotion, reduceMotion)
        .environment(\.colorScheme, .dark)
    }

    private func shapeAnimation(opening: Bool) -> Animation {
        if reduceMotion {
            return Motion.close
        }
        return opening ? Motion.open : Motion.close.delay(Motion.closeDelay)
    }

    // content comes in just after the shape starts, and leaves before it closes
    private var contentTransition: AnyTransition {
        if reduceMotion {
            #if DEBUG
            DebugMotion.noteTransition("open", "opacity")
            #endif
            return .opacity.animation(Motion.reduced)
        }
        #if DEBUG
        DebugMotion.noteTransition("open", "opacity and scale")
        #endif
        return .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
                .animation(Motion.content.delay(max(0, Motion.contentDelay - viewModel.contentLag))),
            removal: .opacity.animation(Motion.fadeOut))
    }
}

// what the open island shows, drop zone first, then card, status, tiles or a panel
struct IslandContentView: View {
    @ObservedObject var viewModel: IslandViewModel
    @Binding var isDropTargeted: Bool
    @Environment(\.islandReduceMotion) private var reduceMotion

    var body: some View {
        #if DEBUG
        let _ = BodyCounts.note("IslandContentView")
        #endif
        ZStack(alignment: .top) {
            switch viewModel.content {
            case .dropZone:
                DropZoneView(viewModel: viewModel, isDropTargeted: $isDropTargeted)
                    .transition(swap)
            case .card:
                SuggestionCardView(model: viewModel)
                    .transition(swap)
            case .status:
                if let status = viewModel.status {
                    StatusView(status: status)
                        .transition(swap)
                }
            case .home:
                HomeView(model: viewModel, activity: viewModel.activity, storage: viewModel.storage)
                    .transition(swap)
            case .activity:
                ActivityView(activity: viewModel.activity, model: viewModel)
                    .transition(swap)
            case .storage:
                StorageView(storage: viewModel.storage, model: viewModel)
                    .transition(swap)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? Motion.reduced : Motion.content, value: viewModel.content)
    }

    private var swap: AnyTransition {
        if reduceMotion {
            #if DEBUG
            DebugMotion.noteTransition("swap", "opacity")
            #endif
            return .opacity
        }
        #if DEBUG
        DebugMotion.noteTransition("swap", "opacity and scale")
        #endif
        return .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
    }
}

// three tiles under the notch
struct HomeView: View {
    @ObservedObject var model: IslandViewModel
    // the tiles show these, so a send or a refresh landing redraws them
    @ObservedObject var activity: ActivityStore
    @ObservedObject var storage: StorageStatus

    var body: some View {
        HStack(spacing: DesignConstants.tileSpacing) {
            ForEach(Tile.allCases) { tile in
                TileView(tile: tile, content: model.tileContent(tile), model: model)
            }
        }
        .padding(.top, DesignConstants.notchBand + 16)
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

// a full panel opened from a tile, back with the chevron
struct DetailPanel<Content: View>: View {
    let title: String
    let onBack: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Back")
                .debugFrame("back")
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
            }
            content()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, DesignConstants.notchBand + 4)
        .padding(.bottom, 16)
        .foregroundStyle(.white)
    }
}

// an icon and one line, for empty panels
struct PanelNote: View {
    let symbol: String
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 24))
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// a finder drag over the island, drops go to the card
struct DropZoneView: View {
    @ObservedObject var viewModel: IslandViewModel
    @Binding var isDropTargeted: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.circle")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 28, weight: .medium))
            Text("Drop to send to Drive")
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.top, DesignConstants.notchBand)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            // "classifying" shows before any file has loaded
            viewModel.handleDrop(providers)
            return true
        }
    }
}

#Preview("home") {
    IslandView(viewModel: {
        let model = IslandViewModel()
        model.expand()
        return model
    }())
    .frame(width: DesignConstants.windowWidth, height: DesignConstants.expandedHeight)
    .background(Color.gray)
}
