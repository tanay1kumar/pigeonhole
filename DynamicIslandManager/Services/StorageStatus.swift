import Foundation
import Combine

// the two calls the quota cache makes, tests keep it in a dictionary
protocol QuotaDefaults {
    func data(forKey: String) -> Data?
    func set(_ value: Any?, forKey: String)
}

extension UserDefaults: QuotaDefaults {}

// drive's quota for the storage tile, cached so the tile isn't empty after launch
// refreshed when the island opens and it's older than 10 minutes or the last try failed, after a send,
// and after signing in to an empty cache, never on a timer
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

    // the tile, the panel and settings say the same thing before there's a quota
    var placeholder: String {
        guard let lastError else { return "Checking…" }
        switch lastError.category {
        case .authExpired: return "Signed out"
        case .offline: return "Offline"
        // drive itself failed, not the network
        default: return "Can't check"
        }
    }

    var isOld: Bool {
        fetchedAt.map { now().timeIntervalSince($0) > Self.maxAge } ?? true
    }

    func refreshIfOld() {
        // fetchedAt only moves on success, so a failed refresh is tried again on the next open
        guard isOld || isStale else { return }
        refresh(reason: fetchedAt == nil ? "never checked" : isOld ? "older than 10 min" : "the last one failed")
    }

    func refresh(reason: String) {
        #if DEBUG
        // the demo's made-up numbers stay put
        if let debugPinned {
            about = debugPinned
            fetchedAt = now()
            lastError = nil
            return
        }
        #endif
        guard refreshing == nil else { return }
        print("storage: refreshing, \(reason)")
        refreshing = Task { [weak self] in
            guard let self else { return }
            do {
                let about = try await self.fetch()
                // signed out while this was out, it's the old account's
                guard !Task.isCancelled else { return }
                self.about = about
                self.fetchedAt = self.now()
                self.lastError = nil
                self.save()
            } catch {
                guard !Task.isCancelled else { return }
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

    // signed out, the next account mustn't see this one's name or quota
    func reset() {
        refreshing?.cancel()
        refreshing = nil
        soon?.cancel()
        soon = nil
        about = nil
        fetchedAt = nil
        // the account pane says signed out instead of checking forever
        lastError = .notSignedIn
        defaults?.set(nil, forKey: Self.defaultsKey)
    }

    #if DEBUG
    // the scenario ages the cache instead of waiting 10 minutes
    func debugAge(by seconds: TimeInterval) {
        fetchedAt = fetchedAt?.addingTimeInterval(-seconds)
    }

    // the readme demo, made-up numbers in memory only, never saved
    private var debugPinned: DriveAbout?

    func debugPin(_ about: DriveAbout) {
        debugPinned = about
        // a real refresh still out mustn't land on top
        refreshing?.cancel()
        refreshing = nil
        refresh(reason: "demo")
    }
    #endif

    private func save() {
        guard let defaults, let about, let fetchedAt,
              let data = try? JSONEncoder().encode(Saved(about: about, fetchedAt: fetchedAt)) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
