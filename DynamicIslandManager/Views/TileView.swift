import SwiftUI

// the three tiles on the open island
enum Tile: String, CaseIterable, Identifiable {
    case activity, storage, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .activity: return "Activity"
        case .storage: return "Storage"
        case .settings: return "Settings"
        }
    }
}

// what a tile shows, a big value and a caption under it
struct TileContent: Equatable {
    var value: String?          // "12", "4.2 GB"
    var caption: String         // "this week", "free"
    var ring: Double?           // storage used, 0...1
    var dimmed = false          // stale or never fetched
}

// control center style, icon top left, live content bottom left
struct TileView: View {
    let tile: Tile
    let content: TileContent
    // not observed, the tile only redraws when its content changes
    let model: IslandViewModel
    @State private var isHovered = false

    var body: some View {
        #if DEBUG
        let _ = BodyCounts.note("TileView")
        #endif
        Button {
            model.tileTapped(tile)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                icon
                    .frame(height: 24, alignment: .topLeading)
                Spacer(minLength: 0)
                if let value = content.value {
                    Text(value)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Text(content.caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .opacity(content.dimmed ? 0.55 : 1)
            .padding(12)
            .frame(width: DesignConstants.tileSize, height: DesignConstants.tileSize, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(isHovered ? 0.13 : 0.08))
            )
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityLabel(accessibilityText)
        .debugFrame("tile-\(tile.rawValue)")
    }

    @ViewBuilder
    private var icon: some View {
        switch tile {
        case .activity:
            Image(systemName: "clock.arrow.circlepath")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 18, weight: .medium))
        case .storage:
            StorageRing(used: content.ring)
                .frame(width: 22, height: 22)
        case .settings:
            Image(systemName: "gearshape")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 18, weight: .medium))
        }
    }

    private var accessibilityText: String {
        [tile.title, content.value, content.caption].compactMap { $0 }.joined(separator: ", ")
    }
}

// small used-space ring, a plain circle until there's a number
struct StorageRing: View {
    let used: Double?

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.18), lineWidth: 3)
            if let used {
                Circle()
                    .trim(from: 0, to: min(max(used, 0), 1))
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .padding(1.5)
    }
}

// tiles shrink a little while pressed
struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

#Preview {
    let model = IslandViewModel()
    return HStack(spacing: DesignConstants.tileSpacing) {
        ForEach(Tile.allCases) { tile in
            TileView(tile: tile, content: model.tileContent(tile), model: model)
        }
    }
    .padding(24)
    .background(Color.black)
    .environment(\.colorScheme, .dark)
}
