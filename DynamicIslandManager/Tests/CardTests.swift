#if DEBUG
import AppKit
import UniformTypeIdentifiers

// stands in for drive in card tests: remembers where each file went and what was deleted
@MainActor
final class FakeCardDrive: DriveUploading {
    struct Upload: Equatable {
        let name: String
        let parentId: String?
        let fileId: String
    }

    private(set) var uploads: [Upload] = []
    private(set) var deleted: [String] = []
    var failNames: Set<String> = []          // these uploads fail (once each)
    var nextUploadError: DriveError?         // the next upload fails with this
    var failDeletes = 0                      // the next n deletes fail
    var deleteError = DriveError(category: .offline)
    var missingIds: Set<String> = []         // deleting these says 404
    var hold = false            // uploads and deletes wait for release()
    private var gate: CheckedContinuation<Void, Never>?
    private var counter = 0

    var isWaiting: Bool { gate != nil }

    func release() {
        gate?.resume()
        gate = nil
    }

    func uploadFile(_ fileItem: FileItem, to parentId: String?) async throws -> DriveFile {
        if hold {
            await withCheckedContinuation { gate = $0 }
        }
        if failNames.contains(fileItem.name) {
            failNames.remove(fileItem.name)
            throw DriveError(category: .offline)
        }
        if let error = nextUploadError {
            nextUploadError = nil
            throw error
        }
        counter += 1
        let id = "file\(counter)"
        uploads.append(Upload(name: fileItem.name, parentId: parentId, fileId: id))
        return DriveFile(id: id, name: fileItem.name, parents: parentId.map { [$0] }, mimeType: nil)
    }

    func deleteFile(id: String, protectedIds: Set<String>) async throws {
        if hold {
            await withCheckedContinuation { gate = $0 }
        }
        guard !protectedIds.contains(id) else { throw DriveError.refused("protected") }
        if failDeletes > 0 {
            failDeletes -= 1
            throw deleteError
        }
        if missingIds.contains(id) {
            throw DriveError(category: .notFound, status: 404)
        }
        deleted.append(id)
    }
}

enum CardTests: TestSuite {
    static let name = "Card"

    static let flowers = Destination(id: "dest-flowers", name: "Flowers", path: "Flowers")
    static let receipts = Destination(id: "dest-receipts", name: "Receipts", path: "Receipts")
    static let resumes = Destination(id: "dest-resumes", name: "Resumes", path: "Resumes")

    struct Setup {
        let model: IslandViewModel
        let drive: FakeCardDrive
        let store: LearningStore
        let destinations: DestinationStore
        let dir: URL
    }

    @MainActor
    static func setup(_ t: TestContext, destinations list: [Destination] = [flowers, receipts, resumes]) throws -> Setup {
        let drive = FakeCardDrive()
        let store = LearningStore(fileURL: nil)
        let destinations = DestinationStore()
        destinations.debugUseInMemory(list)
        let model = IslandViewModel(driveService: drive, destinationStore: destinations,
                                    classifier: DestinationClassifier(store: store), extractor: FeatureExtractor())
        model.timing.undoWindow = 0.3
        model.timing.unattended = 30
        model.timing.parkRecheck = 0.02
        model.expand()
        return Setup(model: model, drive: drive, store: store, destinations: destinations, dir: try t.tempDirectory())
    }

    static func receiptFile(_ dir: URL, _ name: String = "receipt.txt") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("TOTAL 14.55 SUBTOTAL 13.47 TAX 1.08 VISA ****1234 THANK YOU receipt cashier store".utf8).write(to: url)
        return url
    }

    static func resumeFile(_ dir: URL, _ name: String = "resume.txt") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("Resume. Experience: software engineering internship. Education: bachelor of science. Skills: Swift, Python.".utf8).write(to: url)
        return url
    }

    static func providers(_ urls: [URL]) -> [NSItemProvider] {
        urls.map { NSItemProvider(object: $0 as NSURL) }
    }

    @MainActor
    static func dropAndWait(_ t: TestContext, _ s: Setup, _ urls: [URL]) async {
        s.model.handleDrop(providers(urls))
        await t.eventually("classified", timeout: 10) {
            s.model.cardState == .suggesting && !s.model.suggestions.contains { $0.status == .classifying }
        }
    }

    @MainActor
    static func row(_ s: Setup, _ name: String) -> FileSuggestion? {
        s.model.suggestions.first { $0.file.name == name }
    }

    static var tests: [TestCase] {
        [
            TestCase("a drop shows classifying at once, then suggests the right folder") { t in
                let s = try setup(t)
                let url = try receiptFile(s.dir)
                s.model.handleDrop(providers([url]))
                t.expectEqual(s.model.cardState, .classifying, "synchronously")
                t.expect(s.model.holdsExpanded)
                await t.eventually(timeout: 10) { s.model.cardState == .suggesting }
                guard let row = row(s, "receipt.txt") else {
                    t.fail("no row")
                    return
                }
                t.expectEqual(row.top?.id, receipts.id)
                t.expectEqual(row.chosen?.id, receipts.id)
                t.expect(row.level != .noIdea)
                t.expect(!row.why.isEmpty)
                t.expect(s.model.lastDropToRank != nil)
            },
            TestCase("send, then the undo window ends and the card goes") { t in
                let s = try setup(t)
                await dropAndWait(t, s, [try receiptFile(s.dir)])
                let id = s.model.suggestions[0].id
                s.model.send(id)
                await t.eventually { if case .sent = s.model.cardState { return true }; return false }
                t.expectEqual(s.drive.uploads.map(\.parentId), [receipts.id])
                t.expectEqual(s.model.sentSummary, "Sent to Receipts")
                t.expectEqual(s.store.data(for: receipts.id)?.examples.map(\.weight), [1], "accepted, weight 1")
                await t.eventually("undo window over") { s.model.cardState == .idle }
                t.expect(s.model.suggestions.isEmpty)
                t.expect(!s.model.holdsExpanded)
            },
            TestCase("undo deletes and reopens; sending elsewhere is a correction without a second negative") { t in
                let s = try setup(t)
                s.model.timing.undoWindow = 5
                await dropAndWait(t, s, [try receiptFile(s.dir)])
                let id = s.model.suggestions[0].id
                s.model.send(id)
                await t.eventually { if case .sent = s.model.cardState { return true }; return false }
                s.model.undo()
                await t.eventually { s.model.cardState == .suggesting }
                t.expectEqual(s.drive.deleted, ["file1"])
                t.expect(row(s, "receipt.txt")?.reopened == true)
                t.expectEqual(s.store.data(for: receipts.id)?.examples.count ?? 0, 0, "the batch was undone")
                t.expectEqual(s.store.data(for: receipts.id)?.negatives.count, 1, "one negative per undone file")
                s.model.send(id, to: resumes)
                await t.eventually { if case .sent = s.model.cardState { return true }; return false }
                t.expectEqual(s.drive.uploads.last?.parentId, resumes.id)
                t.expectEqual(s.store.data(for: resumes.id)?.examples.map(\.weight), [2], "corrected, weight 2")
                t.expectEqual(s.store.data(for: receipts.id)?.negatives.count, 1, "no second negative")
            },
            TestCase("picking another chip is a correction with a negative for the top") { t in
                let s = try setup(t)
                await dropAndWait(t, s, [try receiptFile(s.dir)])
                let id = s.model.suggestions[0].id
                t.expectEqual(s.model.suggestions[0].top?.id, receipts.id)
                s.model.send(id, to: flowers)
                await t.eventually { if case .sent = s.model.cardState { return true }; return false }
                t.expectEqual(s.drive.uploads.map(\.parentId), [flowers.id])
                t.expectEqual(s.store.data(for: flowers.id)?.examples.map(\.weight), [2])
                t.expectEqual(s.store.data(for: receipts.id)?.negatives.map(\.value), [0.5])
            },
            TestCase("send all needs every no-idea row picked; untouched rows learn at their level") { t in
                let s = try setup(t)
                let song = s.dir.appendingPathComponent("song.mp3")
                try Data("x".utf8).write(to: song)
                await dropAndWait(t, s, [try receiptFile(s.dir), try resumeFile(s.dir), song])
                t.expectEqual(s.model.suggestions.map(\.file.name), ["receipt.txt", "resume.txt", "song.mp3"], "drop order")
                guard let songRow = row(s, "song.mp3"), songRow.level == .noIdea else {
                    t.fail("song.mp3 should be no idea: \(String(describing: row(s, "song.mp3")?.level))")
                    return
                }
                t.expectEqual(s.model.unpickedNoIdeaCount, 1)
                t.expect(!s.model.canSendAll)
                s.model.sendAll()
                t.expectEqual(s.model.cardState, .suggesting, "send all stays disabled")
                s.model.choose(flowers, for: songRow.id)
                t.expect(s.model.canSendAll)
                let receiptLevel = row(s, "receipt.txt")!.level
                s.model.sendAll()
                await t.eventually(timeout: 5) { if case .sent = s.model.cardState { return true }; return false }
                t.expectEqual(s.drive.uploads.map(\.parentId), [receipts.id, resumes.id, flowers.id], "no zip, each to its folder")
                t.expectEqual(s.model.sentSummary, "Sent 3 files")
                t.expectEqual(s.store.data(for: receipts.id)?.examples.map(\.weight), [receiptLevel == .confident ? 1 : 0.5])
                t.expectEqual(s.store.data(for: flowers.id)?.examples.map(\.weight), [1], "picked at no idea")
                t.expectEqual(s.store.data(for: flowers.id)?.negatives.count ?? 0, 0)
            },
            TestCase("a failed row: retry sends only it, in the same batch") { t in
                let s = try setup(t)
                s.drive.failNames = ["resume.txt"]
                await dropAndWait(t, s, [try receiptFile(s.dir), try resumeFile(s.dir)])
                s.model.sendAll()
                await t.eventually { if case .error(_, retry: .resend) = s.model.cardState { return true }; return false }
                t.expectEqual(s.drive.uploads.map(\.name), ["receipt.txt"])
                let batch = s.model.batchId
                s.model.retry()
                await t.eventually { if case .sent = s.model.cardState { return true }; return false }
                t.expectEqual(s.drive.uploads.map(\.name), ["receipt.txt", "resume.txt"])
                if case .sent(let sentBatch) = s.model.cardState {
                    t.expectEqual(sentBatch, batch, "same batch, so one undo covers both")
                }
            },
            TestCase("undo after a partial send deletes what went") { t in
                let s = try setup(t)
                s.drive.failNames = ["resume.txt"]
                await dropAndWait(t, s, [try receiptFile(s.dir), try resumeFile(s.dir)])
                s.model.sendAll()
                await t.eventually { if case .error(_, retry: .resend) = s.model.cardState { return true }; return false }
                s.model.undo()
                await t.eventually { s.model.cardState == .suggesting }
                t.expectEqual(s.drive.deleted, ["file1"])
            },
            TestCase("a failed undo can be retried; a 404 counts as already gone") { t in
                let s = try setup(t)
                s.model.timing.undoWindow = 5
                await dropAndWait(t, s, [try receiptFile(s.dir), try resumeFile(s.dir)])
                s.model.sendAll()
                await t.eventually { if case .sent = s.model.cardState { return true }; return false }
                s.drive.missingIds = ["file1"]
                s.drive.failDeletes = 1
                s.model.undo()
                await t.eventually { if case .error(_, retry: .undo) = s.model.cardState { return true }; return false }
                s.model.retry()
                await t.eventually { s.model.cardState == .suggesting }
                t.expectEqual(s.drive.deleted, ["file2"], "file1 was a 404, so only file2 needed deleting")
            },
            TestCase("✕ uploads and learns nothing") { t in
                let s = try setup(t)
                await dropAndWait(t, s, [try receiptFile(s.dir)])
                s.model.dismissCard()
                t.expectEqual(s.model.cardState, .idle)
                t.expect(s.model.suggestions.isEmpty)
                t.expect(s.drive.uploads.isEmpty)
                t.expect(s.store.snapshot().isEmpty)
            },
            TestCase("just upload zips several files into my drive, no learning") { t in
                let s = try setup(t)
                await dropAndWait(t, s, [try receiptFile(s.dir), try resumeFile(s.dir)])
                s.model.justUpload()
                await t.eventually { s.model.cardState == .idle && s.model.status?.kind == .success }
                t.expectEqual(s.drive.uploads.count, 1)
                t.expectEqual(s.drive.uploads.first?.parentId, nil)
                t.expect(s.drive.uploads.first?.name.hasSuffix(".zip") == true)
                t.expectEqual(s.model.status?.message, "Uploaded to My Drive")
                t.expect(s.store.snapshot().isEmpty)
            },
            TestCase("the same file twice, or again later, is one row") { t in
                let s = try setup(t)
                let url = try receiptFile(s.dir)
                await dropAndWait(t, s, [url, url])
                t.expectEqual(s.model.suggestions.count, 1)
                s.model.handleDrop(providers([url, try resumeFile(s.dir)]))
                await t.eventually(timeout: 10) { s.model.suggestions.count == 2 && s.model.cardState == .suggesting }
                t.expectEqual(s.model.suggestions.map(\.file.name), ["receipt.txt", "resume.txt"])
            },
            TestCase("a drop during sending waits, then gets its suggestion") { t in
                let s = try setup(t)
                await dropAndWait(t, s, [try receiptFile(s.dir)])
                s.drive.hold = true
                s.model.send(s.model.suggestions[0].id)
                await t.eventually { s.drive.isWaiting }
                s.model.handleDrop(providers([try resumeFile(s.dir)]))
                await t.eventually { row(s, "resume.txt") != nil }
                t.expectEqual(row(s, "resume.txt")?.status, .waiting)
                s.drive.hold = false
                s.drive.release()
                await t.eventually(timeout: 10) { row(s, "resume.txt")?.status == .ready }
                t.expectEqual(row(s, "resume.txt")?.top?.id, resumes.id)
                // the undo window ends and the waiting file keeps its card
                await t.eventually("back to suggesting") { s.model.cardState == .suggesting }
                t.expectEqual(s.model.suggestions.map(\.file.name), ["resume.txt"])
            },
            TestCase("a drop during undo waits, then gets classified") { t in
                let s = try setup(t)
                s.model.timing.undoWindow = 5
                await dropAndWait(t, s, [try receiptFile(s.dir)])
                s.model.send(s.model.suggestions[0].id)
                await t.eventually { if case .sent = s.model.cardState { return true }; return false }
                s.drive.hold = true
                s.model.undo()
                await t.eventually { s.drive.isWaiting }
                t.expectEqual(s.model.cardState, .undoing)
                s.model.handleDrop(providers([try resumeFile(s.dir)]))
                await t.eventually { row(s, "resume.txt")?.status == .waiting }
                s.drive.hold = false
                s.drive.release()
                await t.eventually(timeout: 10) { row(s, "resume.txt")?.status == .ready }
                t.expectEqual(s.model.cardState, .suggesting)
                t.expectEqual(s.model.suggestions.map(\.file.name), ["receipt.txt", "resume.txt"])
                t.expect(row(s, "receipt.txt")?.reopened == true)
            },
            TestCase("a finder drag over the sent card pauses the undo window") { t in
                let s = try setup(t)
                await dropAndWait(t, s, [try receiptFile(s.dir)])
                s.model.send(s.model.suggestions[0].id)
                await t.eventually { if case .sent = s.model.cardState { return true }; return false }
                s.model.fileDragChanged(true)
                try await Task.sleep(for: .milliseconds(700))
                t.expect({ if case .sent = s.model.cardState { return true }; return false }(), "still sent during the drag")
                s.model.fileDragChanged(false)
                try await Task.sleep(for: .milliseconds(150))
                t.expect({ if case .sent = s.model.cardState { return true }; return false }(), "timer starts over")
                await t.eventually("then the window ends") { s.model.cardState == .idle }
            },
            TestCase("✕ while classifying: nothing comes back, and the queued files are never read") { t in
                let s = try setup(t)
                // six images that need vision: two at a time, so four are still queued at ✕
                var files: [URL] = []
                for index in 0..<6 {
                    let url = s.dir.appendingPathComponent("scan\(index).png")
                    TestFiles.writeImage(TestFiles.renderText(TestFiles.receiptText, width: 900, height: 1300, fontSize: 36), to: url)
                    files.append(url)
                }
                let before = await s.model.extractor.extractions
                s.model.handleDrop(providers(files))
                await t.eventually { !s.model.suggestions.isEmpty }
                s.model.dismissCard()
                try await Task.sleep(for: .milliseconds(1500))
                t.expectEqual(s.model.cardState, .idle)
                t.expect(s.model.suggestions.isEmpty)
                t.expect(s.model.featuresById.isEmpty)
                let read = await s.model.extractor.extractions - before
                t.expect(read < 6, "only what was already running finished (\(read) of 6)")
            },
            TestCase("a send that started keeps its folders when the list changes") { t in
                let s = try setup(t)
                await dropAndWait(t, s, [try receiptFile(s.dir), try resumeFile(s.dir)])
                t.expectEqual(s.model.suggestions.map { $0.chosen?.id }, [receipts.id, resumes.id])
                s.drive.hold = true
                s.model.sendAll()
                await t.eventually { s.drive.isWaiting }
                t.expectEqual(s.model.suggestions.map(\.status), [.sending, .sending], "both queued")
                s.destinations.debugUseInMemory([flowers, receipts])
                // whatever touches a queued row now, it goes where it was going when send started
                s.model.suggestions[1].chosen = flowers
                s.model.choose(flowers, for: s.model.suggestions[0].id)
                try await Task.sleep(for: .milliseconds(100))
                t.expectEqual(s.model.suggestions[0].chosen?.id, receipts.id, "a row on its way can't be changed")
                s.drive.hold = false
                s.drive.release()
                await t.eventually { if case .sent = s.model.cardState { return true }; return false }
                t.expectEqual(s.drive.uploads.map(\.parentId), [receipts.id, resumes.id])
                t.expectEqual(s.model.sentSummary, "Sent 2 files")
            },
            TestCase("a drop after sending ends the undo window and starts fresh") { t in
                let s = try setup(t)
                s.model.timing.undoWindow = 5
                await dropAndWait(t, s, [try receiptFile(s.dir)])
                s.model.send(s.model.suggestions[0].id)
                await t.eventually { if case .sent = s.model.cardState { return true }; return false }
                await dropAndWait(t, s, [try resumeFile(s.dir)])
                t.expectEqual(s.model.suggestions.map(\.file.name), ["resume.txt"])
                s.model.undo()
                try await Task.sleep(for: .milliseconds(300))
                t.expectEqual(s.drive.deleted, [], "the earlier send can't be undone anymore")
                t.expectEqual(s.model.cardState, .suggesting)
            },
            TestCase("a removed destination isn't kept as the choice") { t in
                let s = try setup(t)
                await dropAndWait(t, s, [try receiptFile(s.dir)])
                t.expectEqual(s.model.suggestions[0].chosen?.id, receipts.id)
                s.destinations.debugUseInMemory([flowers, resumes])
                await t.eventually { s.model.suggestions[0].chosen?.id != receipts.id }
                t.expect(s.model.suggestions[0].ranked.allSatisfy { $0.destination.id != receipts.id })
            },
            TestCase("no destinations: drops go to the cube grid") { t in
                let s = try setup(t, destinations: [])
                s.model.handleDrop(providers([try receiptFile(s.dir)]))
                t.expectEqual(s.model.cardState, .idle)
                await t.eventually { s.model.droppedFiles.count == 1 }
            },
            TestCase("the card holds the island open; unattended it parks") { t in
                let s = try setup(t)
                s.model.timing.unattended = 0.1
                s.model.pointerIsOverIsland = { false }
                await dropAndWait(t, s, [try receiptFile(s.dir)])
                t.expect(s.model.holdsExpanded)
                s.model.collapse()
                t.expectEqual(s.model.currentState, .expanded, "stays open while the card is up")
                await t.eventually("parks") { s.model.parked && s.model.currentState == .collapsed }
                t.expectEqual(s.model.cardState, .suggesting, "the card is kept")
                s.model.expand()
                t.expect(!s.model.parked && s.model.holdsExpanded)
            },
            TestCase("a dropped folder is one zip row, sent zipped") { t in
                let s = try setup(t)
                let folder = s.dir.appendingPathComponent("Tax Receipts 2024")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                _ = try receiptFile(folder, "a.txt")
                await dropAndWait(t, s, [folder])
                t.expectEqual(s.model.suggestions.first?.displayName, "Tax Receipts 2024.zip")
                s.model.send(s.model.suggestions[0].id, to: receipts)
                await t.eventually { if case .sent = s.model.cardState { return true }; return false }
                t.expectEqual(s.drive.uploads.first?.name, "Tax Receipts 2024.zip")
                t.expectEqual(s.drive.uploads.first?.parentId, receipts.id)
            },
            TestCase("a symlink counts as what it points to, in the card and in zips") { t in
                let dir = try t.tempDirectory()
                let real = dir.appendingPathComponent("real.heic")
                try Data(repeating: 7, count: 5000).write(to: real)
                let link = dir.appendingPathComponent("Sunflower.heic")
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
                let item = FileItem(url: link)
                t.expectEqual(item.size, 5000, "the photo's size, not the link's")
                t.expectEqual(item.name, "Sunflower.heic")
                let folder = dir.appendingPathComponent("Taxes", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data("a".utf8).write(to: folder.appendingPathComponent("a.txt"))
                let folderLink = dir.appendingPathComponent("Taxes link")
                try FileManager.default.createSymbolicLink(at: folderLink, withDestinationURL: folder)
                t.expect(FileItem(url: folderLink).isDirectory, "a link to a folder is a folder")

                // unzip and look: a regular file with the photo's bytes, under the link's name
                let zip = try ZipUtility.zipFiles([item, FileItem(url: real)])
                defer { ZipUtility.cleanupTempFile(at: zip) }
                let out = dir.appendingPathComponent("unzipped")
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                process.arguments = ["-x", "-k", zip.path, out.path]
                try process.run()
                process.waitUntilExit()
                let unzipped = out.appendingPathComponent("Sunflower.heic")
                let values = try unzipped.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
                t.expect(values.isSymbolicLink != true, "not a link inside the zip")
                t.expectEqual(values.fileSize, 5000)
            },
            TestCase("just upload keeps files dropped while it runs, and never strands them") { t in
                let s = try setup(t)
                await dropAndWait(t, s, [try receiptFile(s.dir), try resumeFile(s.dir)])
                s.drive.hold = true
                s.model.justUpload()
                await t.eventually { s.drive.isWaiting }
                let late = s.dir.appendingPathComponent("late.txt")
                try Data("lecture homework exam syllabus".utf8).write(to: late)
                s.model.handleDrop(providers([late]))
                await t.eventually { row(s, "late.txt")?.status == .waiting }
                s.drive.hold = false
                s.drive.release()
                await t.eventually(timeout: 10) { s.model.cardState == .suggesting && row(s, "late.txt")?.status == .ready }
                t.expectEqual(s.model.suggestions.map(\.file.name), ["late.txt"], "only the zipped files left the card")
                t.expectEqual(s.drive.uploads.count, 1)
                t.expectEqual(s.model.cardNote, "Uploaded 2 files to My Drive")

                // a failed just upload: the files dropped meanwhile still get suggestions
                let t2 = try setup(t)
                await dropAndWait(t, t2, [try receiptFile(t2.dir)])
                t2.drive.hold = true
                t2.drive.nextUploadError = DriveError(category: .authExpired, status: 401)
                t2.model.justUpload()
                await t.eventually { t2.drive.isWaiting }
                t2.model.handleDrop(providers([try resumeFile(t2.dir)]))
                await t.eventually { row(t2, "resume.txt")?.status == .waiting }
                t2.drive.hold = false
                t2.drive.release()
                await t.eventually(timeout: 10) { row(t2, "resume.txt")?.status == .ready }
                t.expectEqual(t2.model.cardState, .suggesting)
                t.expect(t2.model.authExpired, "the card offers sign-in")
                t.expect(t2.model.cardNote?.hasPrefix("Couldn't upload") == true)
            },
            TestCase("after a failed undo, new drops wait and a sent file is never sent twice") { t in
                let s = try setup(t)
                s.model.timing.undoWindow = 5
                let receipt = try receiptFile(s.dir)
                await dropAndWait(t, s, [receipt])
                s.model.send(s.model.suggestions[0].id)
                await t.eventually { if case .sent = s.model.cardState { return true }; return false }
                s.drive.failDeletes = 1
                s.model.undo()
                await t.eventually { if case .error(_, retry: .undo) = s.model.cardState { return true }; return false }
                // the same file again (deduped) and a new one
                s.model.handleDrop(providers([receipt, try resumeFile(s.dir)]))
                await t.eventually { row(s, "resume.txt") != nil }
                try await Task.sleep(for: .milliseconds(200))
                t.expect({ if case .error(_, retry: .undo) = s.model.cardState { return true }; return false }(), "still the undo error")
                t.expectEqual(row(s, "resume.txt")?.status, .waiting)
                s.model.send(s.model.suggestions[0].id)
                try await Task.sleep(for: .milliseconds(200))
                t.expectEqual(s.drive.uploads.count, 1, "the sent receipt isn't uploaded again")
                s.model.retry()
                await t.eventually(timeout: 10) { s.model.cardState == .suggesting && row(s, "resume.txt")?.status == .ready }
                t.expectEqual(s.drive.deleted, ["file1"])
            },
            TestCase("✕ on an error lets the failed send go, not files dropped meanwhile") { t in
                let s = try setup(t)
                s.drive.failNames = ["receipt.txt"]
                await dropAndWait(t, s, [try receiptFile(s.dir)])
                s.drive.hold = true
                s.model.send(s.model.suggestions[0].id)
                await t.eventually { s.drive.isWaiting }
                s.model.handleDrop(providers([try resumeFile(s.dir)]))
                await t.eventually { row(s, "resume.txt")?.status == .waiting }
                s.drive.hold = false
                s.drive.release()
                await t.eventually { if case .error(_, retry: .resend) = s.model.cardState { return true }; return false }
                await t.eventually(timeout: 10) { row(s, "resume.txt")?.status == .ready }
                s.model.dismissCard()
                t.expectEqual(s.model.cardState, .suggesting)
                t.expectEqual(s.model.suggestions.map(\.file.name), ["resume.txt"])
            },
            TestCase("✕ on a failed undo takes back what was learned from the batch") { t in
                let s = try setup(t)
                s.model.timing.undoWindow = 5
                await dropAndWait(t, s, [try receiptFile(s.dir)])
                s.model.send(s.model.suggestions[0].id)
                await t.eventually { if case .sent = s.model.cardState { return true }; return false }
                t.expectEqual(s.store.data(for: receipts.id)?.examples.count, 1)
                s.drive.failDeletes = 1
                s.drive.deleteError = DriveError(category: .authExpired, status: 401)
                s.model.undo()
                await t.eventually { if case .error(_, retry: .undo) = s.model.cardState { return true }; return false }
                t.expect(s.model.authExpired, "an expired sign-in during undo offers sign-in")
                s.model.dismissCard()
                await t.eventually { (s.store.data(for: receipts.id)?.examples.count ?? 0) == 0 }
                t.expectEqual(s.model.cardState, .idle)
            },
            TestCase("signing in again doesn't stop an unattended card folding away") { t in
                let s = try setup(t)
                s.model.timing.unattended = 0.3
                s.model.pointerIsOverIsland = { false }
                await dropAndWait(t, s, [try receiptFile(s.dir)])
                s.model.authExpired = true
                NotificationCenter.default.post(name: .didSignIn, object: nil)
                await t.eventually { !s.model.authExpired }
                await t.eventually("still parks") { s.model.parked && s.model.currentState == .collapsed }
            },
            TestCase("a finder drag that starts during the send keeps the undo window waiting") { t in
                let s = try setup(t)
                await dropAndWait(t, s, [try receiptFile(s.dir)])
                s.drive.hold = true
                s.model.send(s.model.suggestions[0].id)
                await t.eventually { s.drive.isWaiting }
                s.model.fileDragChanged(true)
                s.drive.hold = false
                s.drive.release()
                await t.eventually { if case .sent = s.model.cardState { return true }; return false }
                try await Task.sleep(for: .milliseconds(700))
                t.expect({ if case .sent = s.model.cardState { return true }; return false }(), "Undo still there after the window's length")
                s.model.fileDragChanged(false)
                await t.eventually("then the window runs") { s.model.cardState == .idle }
            },
            TestCase("✕ before the files finish loading: they go with the card") { t in
                let s = try setup(t)
                let url = try receiptFile(s.dir)
                let slow = NSItemProvider()
                slow.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
                        completion(url.dataRepresentation, nil)
                    }
                    return nil
                }
                s.model.handleDrop([slow])
                s.model.dismissCard()
                try await Task.sleep(for: .milliseconds(900))
                t.expectEqual(s.model.cardState, .idle)
                t.expect(s.model.suggestions.isEmpty, "nothing came back")
            },
            TestCase("an unreadable drop says so") { t in
                let s = try setup(t)
                let bogus = NSItemProvider(item: "not a file" as NSString, typeIdentifier: "public.plain-text")
                s.model.handleDrop([bogus])
                await t.eventually { if case .error = s.model.cardState { return true }; return false }
                t.expectEqual(s.model.cardState, .error("Couldn't read the dropped files", retry: .none))
            },
        ]
    }
}
#endif
