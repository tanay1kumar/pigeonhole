#if DEBUG
import AppKit

// the activity list, the storage cache and the tiles that show them
enum ActivityTests: TestSuite {
    static let name = "Activity"

    static func entry(_ name: String, daysAgo: Double = 0, bytes: Int64 = 1000, fileId: String? = nil,
                      batch: UUID? = nil, now: Date = Date()) -> ActivityEntry {
        ActivityEntry(kind: .sent, date: now.addingTimeInterval(-daysAgo * 86_400), name: name, bytes: bytes,
                      driveFileId: fileId ?? "id-\(name)", webViewLink: "https://drive.google.com/file/d/id-\(name)/view?usp=drivesdk",
                      destinationId: "dest-flowers", destinationName: "Flowers", batchId: batch)
    }

    // made up, a 15 GB plan with 10 GB used
    static let about = DriveAbout(storageQuota: .init(limit: "16106127360", usage: "10737418240",
                                                       usageInDrive: "4294967296", usageInDriveTrash: "0"),
                                  user: .init(emailAddress: "someone@example.com", displayName: "Someone"))

    // in memory, a defaults domain leaves an empty plist behind on every run
    final class MemoryDefaults: QuotaDefaults {
        var values: [String: Any] = [:]

        func data(forKey key: String) -> Data? {
            values[key] as? Data
        }

        func set(_ value: Any?, forKey key: String) {
            values[key] = value
        }
    }

    static var tests: [TestCase] {
        [
            TestCase("newest first, at most 200 and nothing older than 90 days") { t in
                let store = ActivityStore(fileURL: nil)
                store.record([entry("a", daysAgo: 2), entry("b", daysAgo: 1)])
                store.record([entry("c")])
                t.expectEqual(store.entries.map(\.name), ["c", "b", "a"])
                store.record((0..<205).map { entry("n\($0)", daysAgo: 0.001 * Double($0)) })
                t.expectEqual(store.entries.count, 200)
                t.expectEqual(store.entries.first?.name, "n0")
                store.record([entry("old", daysAgo: 91)])
                t.expect(!store.entries.contains { $0.name == "old" }, "past 90 days it's dropped")
            },
            TestCase("undo takes its files out, the rest stay") { t in
                let store = ActivityStore(fileURL: nil)
                let batch = UUID()
                store.record([entry("a", batch: batch), entry("b", batch: batch), entry("c")])
                store.remove(driveFileIds: ["id-a", "id-b"])
                t.expectEqual(store.entries.map(\.name), ["c"])
            },
            TestCase("this week counts files and bytes, last week doesn't") { t in
                var calendar = Calendar(identifier: .gregorian)
                calendar.firstWeekday = 2
                calendar.timeZone = TimeZone(identifier: "America/Toronto")!
                // a wednesday at noon
                let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 12))!
                let store = ActivityStore(fileURL: nil, now: now)
                store.record([entry("mon", daysAgo: 2, bytes: 100, now: now), entry("wed", bytes: 50, now: now),
                              entry("last weekend", daysAgo: 3.6, bytes: 7, now: now)], now: now)
                let week = store.summary(now: now, calendar: calendar)
                t.expectEqual(week.files, 2)
                t.expectEqual(week.bytes, 150)
            },
            TestCase("saved next to the learning file and read back after a relaunch") { t in
                let url = try t.tempDirectory().appendingPathComponent("activity.json")
                let store = ActivityStore(fileURL: url, writeDelay: 30)
                store.record([entry("a"), entry("b")])
                t.expect(!FileManager.default.fileExists(atPath: url.path), "written later, not on every send")
                store.flush()
                let again = ActivityStore(fileURL: url)
                t.expectEqual(again.entries, store.entries)
                let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
                t.expectEqual(mode, 0o600, "only this user can read the file names")
            },
            TestCase("a write after a pause, without a flush") { t in
                let url = try t.tempDirectory().appendingPathComponent("activity.json")
                let store = ActivityStore(fileURL: url, writeDelay: 0.05)
                store.record([entry("a")])
                await t.eventually { FileManager.default.fileExists(atPath: url.path) }
                t.expectEqual(ActivityStore(fileURL: url).entries.map(\.name), ["a"])
            },
            TestCase("clear empties it and deletes the file") { t in
                let url = try t.tempDirectory().appendingPathComponent("activity.json")
                let store = ActivityStore(fileURL: url, writeDelay: 30)
                store.record([entry("a")])
                store.flush()
                store.clear()
                t.expect(store.entries.isEmpty)
                t.expect(!FileManager.default.fileExists(atPath: url.path))
                t.expect(ActivityStore(fileURL: url).entries.isEmpty, "nothing comes back after a relaunch")
            },
            TestCase("a damaged file starts empty instead of failing") { t in
                let url = try t.tempDirectory().appendingPathComponent("activity.json")
                try Data("not json".utf8).write(to: url)
                t.expect(ActivityStore(fileURL: url).entries.isEmpty)
            },
            TestCase("a drive entry opens its link, or a page made from the id") { t in
                t.expectEqual(entry("a").driveURL?.absoluteString, "https://drive.google.com/file/d/id-a/view?usp=drivesdk")
                let bare = ActivityEntry(kind: .justUploaded, name: "x.zip", bytes: 1, driveFileId: "X1", destinationName: "My Drive")
                t.expectEqual(bare.driveURL?.absoluteString, "https://drive.google.com/file/d/X1/view")
            },
            TestCase("copy link writes one link a line") { t in
                let board = NSPasteboard(name: NSPasteboard.Name("DynamicIslandManager.tests.\(UUID().uuidString)"))
                let saved = LinkActions.pasteboard
                LinkActions.pasteboard = board
                defer {
                    LinkActions.pasteboard = saved
                    board.releaseGlobally()
                }
                LinkActions.copy([URL(string: "https://a.example/1")!, URL(string: "https://a.example/2")!])
                t.expectEqual(board.string(forType: .string), "https://a.example/1\nhttps://a.example/2")
                t.expect(!LinkActions.copy([]), "nothing to copy leaves the pasteboard alone")
                t.expectEqual(board.string(forType: .string), "https://a.example/1\nhttps://a.example/2")
            },
            TestCase("the storage cache fills the tile after a relaunch") { t in
                let defaults = MemoryDefaults()
                let first = StorageStatus(defaults: defaults) { about }
                first.refresh(reason: "test")
                await t.eventually { first.about != nil }
                let again = StorageStatus(defaults: defaults) { throw DriveError(category: .offline) }
                t.expectEqual(again.about, about)
                t.expect(again.fetchedAt != nil)
            },
            TestCase("storage refreshes on open only once it's older than 10 minutes") { t in
                var clock = Date()
                var calls = 0
                let storage = StorageStatus(defaults: nil, now: { clock }) {
                    calls += 1
                    return about
                }
                storage.refreshIfOld()
                await t.eventually { storage.about != nil }
                t.expectEqual(calls, 1, "never checked")
                clock = clock.addingTimeInterval(9 * 60)
                storage.refreshIfOld()
                try? await Task.sleep(for: .milliseconds(30))
                t.expectEqual(calls, 1, "9 minutes is still fresh")
                clock = clock.addingTimeInterval(2 * 60)
                storage.refreshIfOld()
                await t.eventually { calls == 2 }
            },
            TestCase("a failed refresh keeps the last numbers, dimmed") { t in
                var fail = false
                let storage = StorageStatus(defaults: nil) {
                    if fail { throw DriveError(category: .offline) }
                    return about
                }
                storage.refresh(reason: "test")
                await t.eventually { storage.about != nil }
                fail = true
                storage.refresh(reason: "test")
                await t.eventually { storage.isStale }
                t.expectEqual(storage.about, about)
                fail = false
                storage.refresh(reason: "test")
                await t.eventually { !storage.isStale }
            },
            TestCase("signing out forgets the account, and a refresh still out can't bring it back") { t in
                let defaults = MemoryDefaults()
                var slow = false
                let storage = StorageStatus(defaults: defaults) {
                    if slow {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    return about
                }
                storage.refresh(reason: "test")
                await t.eventually { storage.about != nil }
                t.expect(defaults.data(forKey: StorageStatus.defaultsKey) != nil, "cached")
                slow = true
                storage.refresh(reason: "test")
                storage.reset()
                t.expect(storage.about == nil && storage.fetchedAt == nil, "nothing shown")
                t.expect(storage.isStale, "the pane says it couldn't check")
                t.expect(defaults.data(forKey: StorageStatus.defaultsKey) == nil, "the cache is gone too")
                try? await Task.sleep(for: .milliseconds(250))
                t.expect(storage.about == nil, "the old account's answer is dropped")
                slow = false
                storage.refreshIfOld()
                await t.eventually { storage.about != nil && !storage.isStale }
            },
            TestCase("a failed refresh is tried again on the next open") { t in
                var fail = false
                var calls = 0
                let storage = StorageStatus(defaults: nil) {
                    calls += 1
                    if fail { throw DriveError(category: .offline) }
                    return about
                }
                storage.refreshIfOld()
                await t.eventually { storage.about != nil }
                // the one after a send fails while the last good one is still fresh
                fail = true
                storage.refresh(reason: "test")
                await t.eventually { storage.isStale }
                fail = false
                storage.refreshIfOld()
                await t.eventually { !storage.isStale }
                t.expectEqual(calls, 3)
            },
            TestCase("one refresh at a time, and one after a send") { t in
                var calls = 0
                var slow = true
                let storage = StorageStatus(defaults: nil) {
                    calls += 1
                    if slow {
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    return about
                }
                storage.refresh(reason: "test")
                storage.refresh(reason: "test")
                await t.eventually { storage.about != nil }
                t.expectEqual(calls, 1)
                // a quick fetch, so only the wait can fold two sends into one refresh
                slow = false
                storage.afterSendDelay = 0.2
                storage.refreshSoon()
                try? await Task.sleep(for: .milliseconds(50))
                t.expectEqual(calls, 1, "it waits for drive to count the file")
                storage.refreshSoon()
                await t.eventually { calls == 2 }
                try? await Task.sleep(for: .milliseconds(300))
                t.expectEqual(calls, 2, "two sends close together, one refresh")
            },
        ]
    }
}
#endif
