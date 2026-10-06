import Foundation
import Combine

// the two calls the quota cache makes, tests keep it in a dictionary
protocol QuotaDefaults {
    func data(forKey: String) -> Data?
    func set(_ value: Any?, forKey: String)
}

extension UserDefaults: QuotaDefaults {}

// drive's quota for the storage tile, cached so the tile isn't empty after launch
// refreshed when the island opens and it's older than 10 minutes, and after a send, never on a timer
@MainActor
final class StorageStatus: ObservableObject {
    static let maxAge: TimeInterval = 10 * 60
    static let defaultsKey = "storageQuota"

    @Published private(set) var about: DriveAbout?
    @Published private(set) var fetchedAt: Date?
    // the last refresh failed, the tile dims what it has
    @Published private(set) var lastError: DriveError?
    // drive takes a moment to count a new file
    var afterSendDelay: Double = 3
    private var refreshing: Task<Void, Never>?
    private var soon: Task<Void, Never>?
    private let defaults: QuotaDefaults?
    private let fetch: () async throws -> DriveAbout
    private let now: () -> Date

    private struct Saved: Codable {
        var about: DriveAbout
        var fetchedAt: Date
    }

    // nil defaults keeps it in memory, cli modes and tests
    init(defaults: QuotaDefaults?, now: @escaping () -> Date = Date.init, fetch: @escaping () async throws -> DriveAbout) {
        self.defaults = defaults
        self.fetch = fetch
        self.now = now
        if let data = defaults?.data(forKey: Self.defaultsKey), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            about = saved.about
            fetchedAt = saved.fetchedAt
        }
    }

    var isStale: Bool {
        lastError != nil
    }

    var isOld: Bool {
        fetchedAt.map { now().timeIntervalSince($0) > Self.maxAge } ?? true
    }

    func refreshIfOld() {
        guard isOld else { return }
        refresh(reason: fetchedAt == nil ? "never checked" : "older than 10 min")
    }

    func refresh(reason: String) {
        guard refreshing == nil else { return }
        print("storage: refreshing, \(reason)")
        refreshing = Task { [weak self] in
            guard let self else { return }
            do {
                let about = try await self.fetch()
                self.about = about
                self.fetchedAt = self.now()
                self.lastError = nil
                self.save()
            } catch {
                let driveError = DriveError.from(error)
                self.lastError = driveError
                print("storage: refresh failed, \(driveError.shortText)")
            }
            self.refreshing = nil
        }
    }

    // a send just changed the numbers, one refresh once drive has counted them
    func refreshSoon() {
        soon?.cancel()
        let delay = afterSendDelay
        soon = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.soon = nil
            self.refresh(reason: "after a send")
        }
    }

    #if DEBUG
    // the scenario ages the cache instead of waiting 10 minutes
    func debugAge(by seconds: TimeInterval) {
        fetchedAt = fetchedAt?.addingTimeInterval(-seconds)
    }
    #endif

    private func save() {
        guard let defaults, let about, let fetchedAt,
              let data = try? JSONEncoder().encode(Saved(about: about, fetchedAt: fetchedAt)) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
