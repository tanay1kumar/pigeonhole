import Foundation
import Combine

// one thing the island did with a file
struct ActivityEntry: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case sent, justUploaded, savedToMac
    }

    let id: UUID
    let kind: Kind
    let date: Date
    let name: String                // final name, the converted one if it was converted
    let convertedFrom: String?      // "HEIC"
    let bytes: Int64
    let driveFileId: String?
    let webViewLink: String?
    let destinationId: String?
    let destinationName: String     // "My Drive" for just upload, the folder for save to mac
    let localPath: String?          // save to mac, for show in finder
    let batchId: UUID?

    init(kind: Kind, date: Date = Date(), name: String, convertedFrom: String? = nil, bytes: Int64,
         driveFileId: String? = nil, webViewLink: String? = nil, destinationId: String? = nil,
         destinationName: String, localPath: String? = nil, batchId: UUID? = nil) {
        self.id = UUID()
        self.kind = kind
        self.date = date
        self.name = name
        self.convertedFrom = convertedFrom
        self.bytes = bytes
        self.driveFileId = driveFileId
        self.webViewLink = webViewLink
        self.destinationId = destinationId
        self.destinationName = destinationName
        self.localPath = localPath
        self.batchId = batchId
    }

    // the drive page, made from the id if drive sent no link
    var driveURL: URL? {
        if let webViewLink, let url = URL(string: webViewLink) {
            return url
        }
        return driveFileId.flatMap { URL(string: "https://drive.google.com/file/d/\($0)/view") }
    }
}

// the last sends, kept local next to learning.json, never uploaded
// file names are in it, clear activity deletes it
@MainActor
final class ActivityStore: ObservableObject {
    static let maxEntries = 200
    static let maxAge: TimeInterval = 90 * 24 * 3600

    @Published private(set) var entries: [ActivityEntry] = []   // newest first
    let fileURL: URL?
    private var pendingWrite: Task<Void, Never>?
    private let writeDelay: Double

    // the real file, cli modes and scenarios never touch it
    static var defaultURL: URL {
        LearningStore.defaultURL.deletingLastPathComponent().appendingPathComponent("activity.json")
    }

    // nil keeps everything in memory
    init(fileURL: URL?, writeDelay: Double = 1, now: Date = Date()) {
        self.fileURL = fileURL
        self.writeDelay = writeDelay
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            // dates as plain numbers, exact on the way back
            if let saved = try? JSONDecoder().decode([ActivityEntry].self, from: data) {
                entries = Self.trimmed(saved, now: now)
            } else {
                print("activity: couldn't read the saved list, starting empty")
            }
        }
    }

    func record(_ new: [ActivityEntry], now: Date = Date()) {
        guard !new.isEmpty else { return }
        entries = Self.trimmed(new.sorted { $0.date > $1.date } + entries, now: now)
        scheduleWrite()
    }

    // undo took these files back out of drive
    func remove(driveFileIds ids: Set<String>) {
        let before = entries.count
        entries.removeAll { entry in entry.driveFileId.map(ids.contains) ?? false }
        if entries.count != before {
            scheduleWrite()
        }
    }

    func clear() {
        entries = []
        pendingWrite?.cancel()
        pendingWrite = nil
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    // this calendar week, files and bytes
    func summary(now: Date = Date(), calendar: Calendar = .current) -> (files: Int, bytes: Int64) {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return (0, 0) }
        let thisWeek = entries.filter { week.contains($0.date) }
        return (thisWeek.count, thisWeek.reduce(0) { $0 + $1.bytes })
    }

    // sync, for quitting
    func flush() {
        guard pendingWrite != nil else { return }
        pendingWrite?.cancel()
        pendingWrite = nil
        writeNow()
    }

    static func trimmed(_ list: [ActivityEntry], now: Date) -> [ActivityEntry] {
        Array(list.filter { now.timeIntervalSince($0.date) < maxAge }.prefix(maxEntries))
    }

    private func scheduleWrite() {
        guard fileURL != nil else { return }
        pendingWrite?.cancel()
        let delay = writeDelay
        pendingWrite = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.pendingWrite = nil
            self.writeNow()
        }
    }

    private func writeNow() {
        guard let fileURL else { return }
        do {
            let data = try JSONEncoder().encode(entries)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            // only this user can read it, it has file names
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            print("activity: couldn't save: \(error.localizedDescription)")
        }
    }
}
