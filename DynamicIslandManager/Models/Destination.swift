import Foundation

// drive folder returned by the api
struct DriveFolder: Identifiable, Hashable, Decodable {
    let id: String
    let name: String
}

// a drive folder the user picked as a place for dropped files to go
struct Destination: Identifiable, Codable, Hashable {
    let id: String      // drive folder id
    let name: String
    let path: String    // e.g. "My Drive / Receipts", picked folders only know their own name
}

class DestinationStore: ObservableObject {
    static let maxCount = 8

    @Published private(set) var destinations: [Destination] = []

    private let defaultsKey = "destinations"

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode([Destination].self, from: data) {
            destinations = saved
        }
    }

    var isFull: Bool {
        destinations.count >= Self.maxCount
    }

    func contains(_ folderId: String) -> Bool {
        destinations.contains { $0.id == folderId }
    }

    func add(_ destination: Destination) {
        guard !isFull, !contains(destination.id) else { return }
        destinations.append(destination)
        save()
    }

    func remove(_ folderId: String) {
        destinations.removeAll { $0.id == folderId }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(destinations) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
