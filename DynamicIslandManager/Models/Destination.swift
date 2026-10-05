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
    // "my CVs and cover letters": helps the classifier with oddly named folders.
    // optional, so destinations saved before hints existed still decode
    var hint: String?
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

    // an empty hint means no hint
    func updateHint(id: String, hint: String?) {
        guard let index = destinations.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = hint?.trimmingCharacters(in: .whitespacesAndNewlines)
        let newHint = (trimmed?.isEmpty ?? true) ? nil : trimmed
        guard destinations[index].hint != newHint else { return }
        destinations[index].hint = newHint
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(destinations) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
