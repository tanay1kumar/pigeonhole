#if DEBUG
import AppKit

// activity, storage and copy link on the real island
// sends go to the user's test folders and are deleted afterwards, links are logged, never opened
extension ScenarioRunner {
    // 3 files sent, the tile counts them, the panel lists them newest first, a click gives the link
    func activity() async {
        guard let folders = folders(), let store = app.activityStore else {
            check(app.activityStore != nil, "the app has an activity store")
            return
        }
        let realFile = ActivityStore.defaultURL
        let realBefore = modified(realFile)
        store.clear()
        pointerInside()
        // a long screenshot name, the row still has room for its folder
        let screenshot = outDir.appendingPathComponent("Screenshot 2026-10-06 at 13.39.05.png")
        if !FileManager.default.fileExists(atPath: screenshot.path) {
            try? FileManager.default.copyItem(at: receiptPNG(), to: screenshot)
        }
        await dropAndWait([sunflower, resumePDF(), screenshot])
        let plan: [(String, Destination)] = [("Sunflower.heic", folders.flowers), ("doc_final2.pdf", folders.resumes),
                                             (screenshot.lastPathComponent, folders.receipts)]
        for (name, destination) in plan {
            if let row = model.suggestions.first(where: { $0.file.name == name }) {
                model.choose(destination, for: row.id)
            }
        }
        model.sendAll()
        let ids = await waitForSent("3 files sent")
        check(ids.count == 3, "3 uploads (\(ids.count))")
        // the undo window ends, the island stays open on the tiles
        let home = await waitFor(8) { self.model.cardState == .idle && self.model.content == .home }
        check(home != nil, "back to the tiles after the undo window (\(format(home)))")
        let tile = model.tileContent(.activity)
        check(tile.value == "3" && tile.caption == "this week", "the Activity tile reads 3 this week (\(tile.value ?? "-") \(tile.caption))")
        await snapshot("1-tiles")

        check(await tap("tile-activity"), "clicked the Activity tile")
        let names = store.entries.map(\.name)
        check(names == plan.reversed().map(\.0), "the panel lists them newest first (\(names))")
        let folderNames = store.entries.map(\.destinationName)
        check(folderNames == plan.reversed().map(\.1.name), "each with its folder (\(folderNames))")
        await snapshot("2-panel")
        LinkActions.opened = []
        check(await tap("activity-0"), "clicked the newest row")
        // the click lands a moment after tap returns
        let expected = store.entries.first?.driveURL
        let opened = await waitFor(2) { expected != nil && LinkActions.opened.last == expected }
        check(opened != nil, "it would open \(expected?.absoluteString ?? "-")")

        store.flush()
        let saved = DebugScenarios.activityFileURL.map { ActivityStore(fileURL: $0).entries.count }
        check(saved == 3, "kept in the scenario's own activity file (\(saved ?? 0))")
        check(modified(realFile) == realBefore, "the real activity.json wasn't touched")
        model.show(.home)
    }

    // the quota comes in, the tile and panel show it, an old cache refreshes on open, offline dims it
    func storage() async {
        guard let storage = app.storageStatus else {
            check(false, "the app has a storage status")
            return
        }
        pointerInside()
        model.expand()
        // a fresh cache would pass at once and leave this refresh landing mid-scenario
        let cached = storage.fetchedAt
        storage.refresh(reason: "scenario")
        let fetched = await waitFor(15) { storage.fetchedAt != cached && !storage.isStale }
        check(fetched != nil, "drive's quota came back (\(format(fetched)))")
        guard let about = storage.about else { return }
        print("  quota: \(StorageText.summary(about)), in drive \(StorageText.quota(about.usageInDrive)), trash \(StorageText.quota(about.trash))")
        let tile = model.tileContent(.storage)
        let expected = about.free.map(StorageText.quota) ?? StorageText.quota(about.usage)
        check(tile.value == expected && !tile.dimmed, "the Storage tile shows \(expected) (\(tile.value ?? "-") \(tile.caption))")
        _ = await waitFor(2) { self.model.content == .home }
        check(await tap("tile-storage"), "clicked the Storage tile")
        await snapshot("1-panel")
        LinkActions.opened = []
        check(await tap("manageStorage"), "clicked Manage storage…")
        let manage = await waitFor(2) { LinkActions.opened.last == StorageText.manageURL }
        check(manage != nil, "it would open Google's storage page")

        // a cache older than 10 minutes refreshes on the next open, never on its own
        storage.debugAge(by: 11 * 60)
        let before = storage.fetchedAt
        model.show(.home)
        pointerOutside()
        model.collapse()
        _ = await waitFor(2) { self.model.currentState == .collapsed }
        try? await Task.sleep(for: .seconds(1))
        check(storage.fetchedAt == before, "nothing refreshes while it's closed")
        pointerInside()
        model.expand()
        let refreshed = await waitFor(15) { !storage.isOld }
        check(refreshed != nil, "opening refreshed the old numbers (\(format(refreshed)))")

        // offline keeps the numbers, dimmed
        let online = model.tileContent(.storage)
        drive.transport = FaultTransport(mode: .offline)
        storage.refresh(reason: "scenario, offline")
        let failed = await waitFor(10) { storage.isStale }
        let dimmed = model.tileContent(.storage)
        check(failed != nil && dimmed.dimmed && dimmed.value == online.value, "offline the tile keeps \(dimmed.value ?? "-"), dimmed")
        await snapshot("2-offline")
        drive.transport = URLSessionDriveTransport()
        // the next open tries again, the last good numbers being recent doesn't stop it
        model.show(.home)
        pointerOutside()
        model.collapse()
        _ = await waitFor(2) { self.model.currentState == .collapsed }
        pointerInside()
        model.expand()
        let bright = await waitFor(15) { !storage.isStale }
        check(bright != nil, "back online, the next open brightens it (\(format(bright)))")
    }

    // the sent card's copy link, one link and then a batch, the pasteboard is put back after
    func copyLink() async {
        guard let folders = folders() else { return }
        let board = NSPasteboard.general
        let saved = savePasteboard(board)
        let savedText = board.string(forType: .string)
        pointerInside()
        Haptics.performed = []
        await dropAndWait([receiptPNG()])
        if let row = model.suggestions.first {
            model.send(row.id, to: folders.receipts)
        }
        _ = await waitForSent("one file sent")
        check(Haptics.performed.contains(.levelChange), "the send tapped the trackpad (\(Haptics.performed.count) taps)")
        let link = model.suggestions.first(where: \.isSent)?.driveLink
        check(await tap("copyLink"), "clicked Copy link")
        let copied = await waitFor(2) { link != nil && board.string(forType: .string) == link?.absoluteString }
        check(copied != nil, "the pasteboard has its link")
        await snapshot("1-copied")
        _ = await waitFor(8) { self.model.cardState == .idle }

        await dropAndWait([resumePDF(), sunflower])
        for row in model.suggestions {
            model.choose(row.file.name == "Sunflower.heic" ? folders.flowers : folders.resumes, for: row.id)
        }
        model.sendAll()
        _ = await waitForSent("two files sent")
        let links = model.suggestions.filter(\.isSent).compactMap { $0.driveLink?.absoluteString }
        check(await tap("copyLink"), "clicked Copy link on the batch")
        let lines = await waitFor(2) { links.count == 2 && board.string(forType: .string) == links.joined(separator: "\n") }
        check(lines != nil, "one link a line (\(links.count))")
        // a copy after this one is the user's, keep it
        let ours = board.changeCount
        _ = await waitFor(8) { self.model.cardState == .idle }

        if board.changeCount == ours {
            restorePasteboard(board, saved)
            check(board.string(forType: .string) == savedText, "the pasteboard is back to what was there")
        } else {
            print("  skip: something else was copied during the run, the old pasteboard stays away")
        }
    }

    // the readme recording, made-up activity, storage and account, then the real cursor drives the island
    // real drops send for real, every upload still in activity is deleted when it ends
    //   touch <scenario-out>/demo-stop to end it, or it ends after an hour
    func demo() async {
        guard let store = app.activityStore, let storage = app.storageStatus else {
            check(false, "the app has activity and storage")
            return
        }
        store.clear()
        let hour: TimeInterval = 3600
        let seeded: [(String, String, Int64, TimeInterval, ActivityEntry.Kind, String?)] = [
            ("Q3 expenses.pdf", "receipts", 412_000, 0.3, .sent, nil),
            ("Tulips.jpg", "flowers", 3_100_000, 1.2, .sent, "HEIC"),
            ("Resume - Product Design.pdf", "resumes", 286_000, 3, .sent, nil),
            ("IMG_3920.jpg", "receipts", 1_800_000, 5, .sent, nil),
            ("Lease agreement.pdf", "My Drive", 2_400_000, 20, .justUploaded, nil),
            ("Cover letter.pdf", "resumes", 140_000, 26, .sent, nil),
            ("Peonies.jpg", "flowers", 4_200_000, 28, .sent, nil),
            ("Coffee receipt.png", "receipts", 960_000, 31, .sent, nil),
            ("Project notes.zip", "My Drive", 18_700_000, 44, .justUploaded, nil),
            ("Hydrangea.jpg", "Pictures", 2_900_000, 47, .savedToMac, "HEIC"),
            ("Portfolio.pdf", "resumes", 6_100_000, 120, .sent, nil),
            ("Orchids.jpg", "flowers", 3_600_000, 200, .sent, nil),
        ]
        store.record(seeded.map { name, folder, bytes, hours, kind, from in
            ActivityEntry(kind: kind, date: Date().addingTimeInterval(-hours * hour), name: name, convertedFrom: from,
                          bytes: bytes, destinationName: folder)
        })
        storage.debugPin(DriveAbout(storageQuota: .init(limit: "16106127360", usage: "9870000000",
                                                        usageInDrive: "6420000000", usageInDriveTrash: "184000000"),
                                    user: .init(emailAddress: "alex@example.com", displayName: "Alex Rivera")))
        drive.userEmail = "alex@example.com"

        let stop = outDir.appendingPathComponent("demo-stop")
        try? FileManager.default.removeItem(at: stop)
        print("demo: ready")
        // once a second, not waitFor's 20 ms, so the recording isn't waking the app
        let deadline = Date().addingTimeInterval(3600)
        while !FileManager.default.fileExists(atPath: stop.path) && Date() < deadline {
            try? await Task.sleep(for: .seconds(1))
        }
        print("demo: ending")
        // let an open undo window finish first
        _ = await waitFor(15) { self.model.cardState == .idle }
        pendingDeletes += store.entries.compactMap(\.driveFileId)
        let ids = pendingDeletes
        await deletePendingUploads()
        for id in ids {
            let location = await locate(id)
            check(location == .gone, "demo upload \(id) is gone (\(location))")
        }
    }

    private func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    func savePasteboard(_ board: NSPasteboard) -> [[String: Data]] {
        (board.pasteboardItems ?? []).map { item in
            var types: [String: Data] = [:]
            for type in item.types {
                types[type.rawValue] = item.data(forType: type)
            }
            return types
        }
    }

    func restorePasteboard(_ board: NSPasteboard, _ saved: [[String: Data]]) {
        board.clearContents()
        let items = saved.map { types -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in types {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        board.writeObjects(items)
    }
}
#endif
