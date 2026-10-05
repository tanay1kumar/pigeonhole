#if DEBUG
import Foundation

// MARK: zip

enum ZipUtilityTests: TestSuite {
    static let name = "ZipUtility"

    static func entries(of zip: URL) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        process.arguments = ["-1", zip.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // ditto --sequesterRsrc keeps extended attributes under __MACOSX, like finder's compress
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix("__MACOSX/") }.sorted()
    }

    static var tests: [TestCase] {
        [
            TestCase("same names are de-duplicated") { t in
                let root = try t.tempDirectory()
                var items: [FileItem] = []
                for (index, folder) in ["one", "two", "three"].enumerated() {
                    let dir = root.appendingPathComponent(folder)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let name = index == 2 ? "A.TXT" : "a.txt"
                    items.append(try DriveTestSupport.makeFile(in: dir, named: name, contents: Data(folder.utf8)))
                }
                let zip = try ZipUtility.zipFiles(items)
                defer { ZipUtility.cleanupTempFile(at: zip) }
                let names = entries(of: zip)
                t.expectEqual(names.count, 3, "\(names)")
                t.expectEqual(Set(names.map { $0.lowercased() }).count, 3, "\(names)")
                t.expect(zip.lastPathComponent.hasPrefix("files_") && zip.pathExtension == "zip", zip.lastPathComponent)
            },
            TestCase("unique names") { t in
                var taken = Set<String>()
                t.expectEqual(ZipUtility.uniqueName(for: "a.txt", taken: &taken), "a.txt")
                t.expectEqual(ZipUtility.uniqueName(for: "a.txt", taken: &taken), "a 2.txt")
                t.expectEqual(ZipUtility.uniqueName(for: "A.txt", taken: &taken), "A 3.txt")
                t.expectEqual(ZipUtility.uniqueName(for: "README", taken: &taken), "README")
                t.expectEqual(ZipUtility.uniqueName(for: "README", taken: &taken), "README 2")
                t.expectEqual(ZipUtility.uniqueName(for: "photo.tar.gz", taken: &taken), "photo.tar.gz")
                t.expectEqual(ZipUtility.uniqueName(for: "photo.tar.gz", taken: &taken), "photo.tar 2.gz")
            },
            TestCase("a single folder zips under its own name") { t in
                let root = try t.tempDirectory()
                let folder = root.appendingPathComponent("Trip Photos")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                _ = try DriveTestSupport.makeFile(in: folder, named: "1.txt")
                _ = try DriveTestSupport.makeFile(in: folder, named: "2.txt")
                let item = FileItem(url: folder)
                t.expect(item.isDirectory)
                let zip = try ZipUtility.zipFiles([item])
                defer { ZipUtility.cleanupTempFile(at: zip) }
                t.expectEqual(zip.lastPathComponent, "Trip Photos.zip")
                let names = entries(of: zip)
                t.expect(names.contains("Trip Photos/1.txt") && names.contains("Trip Photos/2.txt"), "\(names)")
            },
            TestCase("nothing to zip throws") { t in
                await t.expectThrows({ try ZipUtility.zipFiles([]) })
            },
            TestCase("missing source throws and leaves no temp folders") { t in
                let root = try t.tempDirectory()
                let tmp = FileManager.default.temporaryDirectory.path
                let before = Set((try? FileManager.default.contentsOfDirectory(atPath: tmp)) ?? []).filter { $0.hasPrefix("zip") }
                let good = try DriveTestSupport.makeFile(in: root, named: "ok.txt")
                let missing = FileItem(url: root.appendingPathComponent("missing.txt"))
                await t.expectThrows({ try ZipUtility.zipFiles([good, missing]) })
                let after = Set((try? FileManager.default.contentsOfDirectory(atPath: tmp)) ?? []).filter { $0.hasPrefix("zip") }
                t.expectEqual(after, before)
            },
            TestCase("cleanup removes the zip and its folder") { t in
                let root = try t.tempDirectory()
                let zip = try ZipUtility.zipFiles([try DriveTestSupport.makeFile(in: root, named: "x.txt"),
                                                   try DriveTestSupport.makeFile(in: root, named: "y.txt")])
                let folder = zip.deletingLastPathComponent()
                t.expect(FileManager.default.fileExists(atPath: zip.path))
                ZipUtility.cleanupTempFile(at: zip)
                t.expect(!FileManager.default.fileExists(atPath: zip.path))
                t.expect(!FileManager.default.fileExists(atPath: folder.path))
            },
        ]
    }
}

// MARK: island status

// stands in for google drive in view model tests
@MainActor
final class FakeUploader: DriveUploading {
    var result: Result<DriveFile, Error> = .success(DriveFile(id: "F1", name: "f", parents: nil, mimeType: nil))
    private(set) var uploads: [FileItem] = []
    private(set) var uploadedExisted: [Bool] = []
    var hold = false
    private var gate: CheckedContinuation<Void, Never>?

    func uploadFile(_ fileItem: FileItem, to parentId: String?) async throws -> DriveFile {
        uploads.append(fileItem)
        uploadedExisted.append(FileManager.default.fileExists(atPath: fileItem.url.path))
        if hold {
            await withCheckedContinuation { gate = $0 }
        }
        return try result.get()
    }

    var isWaiting: Bool { gate != nil }

    func release() {
        gate?.resume()
        gate = nil
    }

    func deleteFile(id: String, protectedIds: Set<String>) async throws {}
}

enum IslandStatusTests: TestSuite {
    static let name = "IslandStatus"

    @MainActor
    static func makeModel(_ uploader: FakeUploader, linger: Double = 0.15, unattended: Double = 30) -> IslandViewModel {
        let model = IslandViewModel(driveService: uploader)
        model.timing.resultLinger = linger
        model.timing.unattended = unattended
        model.timing.parkRecheck = 0.02
        model.expand()
        return model
    }

    static var tests: [TestCase] {
        [
            TestCase("success clears the sent files, then lets go") { t in
                let dir = try t.tempDirectory()
                let uploader = FakeUploader()
                let model = makeModel(uploader)
                model.addFiles([try DriveTestSupport.makeFile(in: dir, named: "a.txt")])
                let ok = await model.uploadDroppedFiles()
                t.expect(ok)
                t.expect(model.droppedFiles.isEmpty)
                t.expectEqual(model.status?.kind, .success)
                t.expect(model.holdsExpanded)
                t.expectEqual(model.lastUploadedFile?.id, "F1")
                t.expectEqual(uploader.uploads.map(\.name), ["a.txt"])
                await t.eventually("status clears after the linger") { model.status == nil && !model.statusPinned }
                t.expect(!model.holdsExpanded)
            },
            TestCase("failure keeps the files queued for another tap") { t in
                let dir = try t.tempDirectory()
                let uploader = FakeUploader()
                uploader.result = .failure(DriveError(category: .offline))
                let model = makeModel(uploader)
                model.addFiles([try DriveTestSupport.makeFile(in: dir, named: "a.txt")])
                let ok = await model.uploadDroppedFiles()
                t.expect(!ok)
                t.expectEqual(model.droppedFiles.count, 1)
                t.expectEqual(model.status, IslandStatus(kind: .failure, message: "You're offline"))
                t.expect(model.statusPinned)
                t.expect(!model.authExpired)
                await t.eventually { model.status == nil && !model.statusPinned }
                t.expectEqual(model.droppedFiles.count, 1, "still queued after the error goes")
                // and a retry works
                uploader.result = .success(DriveFile(id: "F2", name: "a.txt", parents: nil, mimeType: nil))
                t.expect(await model.uploadDroppedFiles())
                t.expect(model.droppedFiles.isEmpty)
            },
            TestCase("other drive errors show their short text") { t in
                let dir = try t.tempDirectory()
                let uploader = FakeUploader()
                let model = makeModel(uploader)
                model.addFiles([try DriveTestSupport.makeFile(in: dir, named: "a.txt")])
                for (error, text) in [(DriveError(category: .permission, status: 403), "No access to that folder"),
                                      (DriveError(category: .server, status: 502), "Drive error (502), retry"),
                                      (DriveError(category: .notFound, status: 404), DriveError(category: .notFound).shortText)] {
                    uploader.result = .failure(error)
                    _ = await model.uploadDroppedFiles()
                    t.expectEqual(model.status?.message, text)
                    t.expectEqual(model.status?.kind, .failure)
                }
                // a non-drive error still says something
                uploader.result = .failure(CocoaError(.fileReadNoPermission))
                _ = await model.uploadDroppedFiles()
                t.expectEqual(model.status?.kind, .failure)
                t.expect(!(model.status?.message.isEmpty ?? true))
            },
            TestCase("auth expired pins a sign-in banner until sign-in") { t in
                let dir = try t.tempDirectory()
                let uploader = FakeUploader()
                uploader.result = .failure(DriveError(category: .authExpired, status: 401))
                let model = makeModel(uploader, linger: 0.05)
                model.addFiles([try DriveTestSupport.makeFile(in: dir, named: "a.txt")])
                _ = await model.uploadDroppedFiles()
                t.expectEqual(model.status?.kind, .signIn)
                t.expect(model.authExpired)
                try await Task.sleep(for: .milliseconds(250))
                t.expectEqual(model.status?.kind, .signIn, "doesn't auto-dismiss")
                t.expect(model.holdsExpanded)
                t.expectEqual(model.droppedFiles.count, 1)

                NotificationCenter.default.post(name: .didSignIn, object: nil)
                await t.eventually("banner clears on sign-in") { model.status == nil && !model.authExpired }
                t.expect(!model.holdsExpanded)
                t.expectEqual(model.droppedFiles.count, 1, "files wait for the next tap")
            },
            TestCase("sign-in notification without an expired session changes nothing") { t in
                let dir = try t.tempDirectory()
                let uploader = FakeUploader()
                uploader.result = .failure(DriveError(category: .offline))
                let model = makeModel(uploader, linger: 5)
                model.addFiles([try DriveTestSupport.makeFile(in: dir, named: "a.txt")])
                _ = await model.uploadDroppedFiles()
                NotificationCenter.default.post(name: .didSignIn, object: nil)
                try await Task.sleep(for: .milliseconds(100))
                t.expectEqual(model.status?.kind, .failure)
            },
            TestCase("collapse is ignored while a status is pinned") { t in
                let dir = try t.tempDirectory()
                let uploader = FakeUploader()
                uploader.result = .failure(DriveError(category: .authExpired))
                let model = makeModel(uploader)
                model.addFiles([try DriveTestSupport.makeFile(in: dir, named: "a.txt")])
                _ = await model.uploadDroppedFiles()
                model.collapse()
                t.expectEqual(model.currentState, .expanded)
                NotificationCenter.default.post(name: .didSignIn, object: nil)
                await t.eventually { !model.holdsExpanded }
                model.collapse()
                t.expectEqual(model.currentState, .collapsed)
            },
            TestCase("collapse is ignored during an upload") { t in
                let dir = try t.tempDirectory()
                let uploader = FakeUploader()
                uploader.hold = true
                let model = makeModel(uploader)
                model.addFiles([try DriveTestSupport.makeFile(in: dir, named: "a.txt")])
                let upload = Task { await model.uploadDroppedFiles() }
                await t.eventually { uploader.isWaiting }
                t.expectEqual(model.status?.kind, .working)
                model.collapse()
                t.expectEqual(model.currentState, .expanded)
                uploader.release()
                _ = await upload.value
            },
            TestCase("a status arriving while collapsed expands the island") { t in
                let dir = try t.tempDirectory()
                let uploader = FakeUploader()
                uploader.hold = true
                uploader.result = .failure(DriveError(category: .offline))
                let model = makeModel(uploader)
                model.addFiles([try DriveTestSupport.makeFile(in: dir, named: "a.txt")])
                let upload = Task { await model.uploadDroppedFiles() }
                await t.eventually { uploader.isWaiting }
                // the island got parked somehow while uploading
                model.parked = true
                model.collapse()
                t.expectEqual(model.currentState, .collapsed)
                uploader.release()
                _ = await upload.value
                t.expectEqual(model.currentState, .expanded)
                t.expect(!model.parked)
            },
            TestCase("an unattended banner parks, hovering brings it back") { t in
                let dir = try t.tempDirectory()
                let uploader = FakeUploader()
                uploader.result = .failure(DriveError(category: .authExpired))
                let model = makeModel(uploader, unattended: 0.1)
                model.pointerIsOverIsland = { false }
                model.addFiles([try DriveTestSupport.makeFile(in: dir, named: "a.txt")])
                _ = await model.uploadDroppedFiles()
                await t.eventually("parks") { model.parked && model.currentState == .collapsed }
                t.expectEqual(model.status?.kind, .signIn, "keeps the banner")
                t.expect(!model.holdsExpanded)
                // hover
                model.expand()
                t.expect(!model.parked)
                t.expect(model.holdsExpanded)
                t.expectEqual(model.currentState, .expanded)
                await t.eventually("parks again") { model.parked }
            },
            TestCase("a drag opens a parked island without bringing the banner back") { t in
                let dir = try t.tempDirectory()
                let uploader = FakeUploader()
                uploader.result = .failure(DriveError(category: .authExpired))
                let model = makeModel(uploader, unattended: 0.05)
                model.pointerIsOverIsland = { false }
                model.addFiles([try DriveTestSupport.makeFile(in: dir, named: "a.txt")])
                _ = await model.uploadDroppedFiles()
                await t.eventually { model.parked && model.currentState == .collapsed }
                // a finder drag (or a drag passing the notch) opens the island
                model.expand(fromDrag: true)
                t.expectEqual(model.currentState, .expanded)
                t.expect(model.parked, "still parked")
                t.expect(!model.holdsExpanded, "so the drag-end collapse goes through")
                model.collapse()
                t.expectEqual(model.currentState, .collapsed)
                // a real hover still brings it back
                model.expand()
                t.expect(!model.parked && model.holdsExpanded)
            },
            TestCase("parking waits while the pointer is over the island") { t in
                let dir = try t.tempDirectory()
                let uploader = FakeUploader()
                uploader.result = .failure(DriveError(category: .authExpired))
                let model = makeModel(uploader, unattended: 0.05)
                var pointerInside = true
                model.pointerIsOverIsland = { pointerInside }
                model.addFiles([try DriveTestSupport.makeFile(in: dir, named: "a.txt")])
                _ = await model.uploadDroppedFiles()
                try await Task.sleep(for: .milliseconds(250))
                t.expect(!model.parked, "pointer is still over it")
                t.expectEqual(model.currentState, .expanded)
                pointerInside = false
                await t.eventually { model.parked && model.currentState == .collapsed }
            },
            TestCase("only the sign-in banner parks") { t in
                let dir = try t.tempDirectory()
                let uploader = FakeUploader()
                uploader.result = .failure(DriveError(category: .offline))
                let model = makeModel(uploader, linger: 1, unattended: 0.05)
                model.addFiles([try DriveTestSupport.makeFile(in: dir, named: "a.txt")])
                _ = await model.uploadDroppedFiles()
                try await Task.sleep(for: .milliseconds(200))
                t.expect(!model.parked)
            },
            TestCase("a double tap uploads once") { t in
                let dir = try t.tempDirectory()
                let uploader = FakeUploader()
                uploader.hold = true
                let model = makeModel(uploader)
                model.addFiles([try DriveTestSupport.makeFile(in: dir, named: "a.txt")])
                let first = Task { await model.uploadDroppedFiles() }
                await t.eventually { uploader.isWaiting }
                let second = await model.uploadDroppedFiles()
                t.expect(!second)
                t.expect(model.isUploading)
                uploader.release()
                t.expect(await first.value)
                t.expectEqual(uploader.uploads.count, 1)
                t.expect(!model.isUploading)
            },
            TestCase("files dropped during an upload stay queued") { t in
                let dir = try t.tempDirectory()
                let uploader = FakeUploader()
                uploader.hold = true
                let model = makeModel(uploader)
                model.addFiles([try DriveTestSupport.makeFile(in: dir, named: "a.txt")])
                let upload = Task { await model.uploadDroppedFiles() }
                await t.eventually { uploader.isWaiting }
                model.addFiles([try DriveTestSupport.makeFile(in: dir, named: "b.txt")])
                uploader.release()
                t.expect(await upload.value)
                t.expectEqual(model.droppedFiles.map(\.name), ["b.txt"])
            },
            TestCase("several files go up as one zip, cleaned up after") { t in
                let dir = try t.tempDirectory()
                let uploader = FakeUploader()
                let model = makeModel(uploader)
                model.addFiles([try DriveTestSupport.makeFile(in: dir, named: "a.txt"),
                                try DriveTestSupport.makeFile(in: dir, named: "b.txt")])
                t.expect(await model.uploadDroppedFiles())
                t.expectEqual(uploader.uploads.count, 1)
                guard let sent = uploader.uploads.first else { return }
                t.expect(sent.name.hasPrefix("files_") && sent.fileExtension == "zip", sent.name)
                t.expectEqual(uploader.uploadedExisted, [true])
                t.expect(!FileManager.default.fileExists(atPath: sent.url.path), "zip removed after upload")
            },
            TestCase("a folder goes up zipped") { t in
                let dir = try t.tempDirectory()
                let folder = dir.appendingPathComponent("Notes")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                _ = try DriveTestSupport.makeFile(in: folder, named: "n.txt")
                let uploader = FakeUploader()
                let model = makeModel(uploader)
                model.addFiles([FileItem(url: folder)])
                t.expect(await model.uploadDroppedFiles())
                t.expectEqual(uploader.uploads.first?.name, "Notes.zip")
            },
            TestCase("a zip failure keeps the files and says so") { t in
                let dir = try t.tempDirectory()
                let uploader = FakeUploader()
                let model = makeModel(uploader)
                model.addFiles([try DriveTestSupport.makeFile(in: dir, named: "a.txt"),
                                FileItem(url: dir.appendingPathComponent("vanished.txt"))])
                t.expect(!(await model.uploadDroppedFiles()))
                t.expectEqual(model.status, IslandStatus(kind: .failure, message: "Couldn't zip the files"))
                t.expectEqual(model.droppedFiles.count, 2)
                t.expectEqual(uploader.uploads.count, 0)
            },
            TestCase("an empty queue does nothing") { t in
                let uploader = FakeUploader()
                let model = makeModel(uploader)
                t.expect(!(await model.uploadDroppedFiles()))
                t.expect(model.status == nil)
                t.expectEqual(uploader.uploads.count, 0)
            },
            TestCase("a new result restarts the linger") { t in
                let dir = try t.tempDirectory()
                let uploader = FakeUploader()
                uploader.result = .failure(DriveError(category: .offline))
                let model = makeModel(uploader, linger: 0.3)
                model.addFiles([try DriveTestSupport.makeFile(in: dir, named: "a.txt")])
                _ = await model.uploadDroppedFiles()
                try await Task.sleep(for: .milliseconds(200))
                _ = await model.uploadDroppedFiles()
                try await Task.sleep(for: .milliseconds(200))
                t.expect(model.status != nil, "the first linger must not clear the second result")
                await t.eventually { model.status == nil }
            },
        ]
    }
}
#endif
