import Foundation

enum IslandState {
    case collapsed
    case expanded
}

// what the tiles open into
enum IslandSurface: Equatable {
    case home, activity, storage
}

// what the open island shows, in priority order
enum IslandContent: Equatable {
    case dropZone, card, status, home, activity, storage
}
