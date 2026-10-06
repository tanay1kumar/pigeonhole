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
        // ditto --sequesterRsrc puts xattrs under __MACOSX like finder's compress
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
final class FakeUploader: DriveClient {
    var result: Result<DriveFile, Error> = .success(DriveFile(id: "F1", name: "f", parents: nil, mimeType: nil))
    private(set) var uploads: [FileItem] = []

    func uploadFile(_ fileItem: FileItem, to parentId: String?, progress: (@Sendable (Double) -> Void)?) async throws -> DriveFile {
        uploads.append(fileItem)
        progress?(1)
        return try result.get()
    }

    func deleteFile(id: String, protectedIds: Set<String>) async throws {}

    func about() async throws -> DriveAbout {
        throw DriveError(category: .offline)
    }
}

// results, shown in place of the tiles
enum IslandStatusTests: TestSuite {
    static let name = "IslandStatus"

    static let uploaded = IslandStatus(kind: .success, message: "Uploaded to My Drive")

    @MainActor
    static func makeModel(linger: Double = 0.15) -> IslandViewModel {
        let model = IslandViewModel(driveService: FakeUploader())
        model.timing.resultLinger = linger
        model.expand()
        return model
    }

    static var tests: [TestCase] {
        [
            TestCase("a result with show in finder stays while the pointer is on it") { t in
                let model = makeModel(linger: 0.05)
                model.timing.parkRecheck = 0.05
                var inside = true
                model.pointerIsOverIsland = { inside }
                model.showUploadResult(IslandStatus(kind: .success, message: "Saved 1 file", reveal: [URL(fileURLWithPath: "/tmp/a.jpg")]))
                try? await Task.sleep(for: .milliseconds(300))
                t.expect(model.status != nil, "still up under the pointer")
                inside = false
                await t.eventually { model.status == nil }
                await t.eventually { model.currentState == .collapsed }
            },
            TestCase("a result shows, holds the island, then lets go") { t in
                let model = makeModel()
                model.pointerIsOverIsland = { true }
                model.showUploadResult(uploaded)
                t.expectEqual(model.status?.kind, .success)
                t.expect(model.holdsExpanded)
                t.expectEqual(model.content, .status)
                await t.eventually("status clears after the linger") { model.status == nil && !model.statusPinned }
                t.expect(!model.holdsExpanded)
                t.expectEqual(model.content, .home)
                t.expectEqual(model.currentState, .expanded, "the pointer is over it, it stays open")
            },
            TestCase("a result letting go with the pointer away closes at once") { t in
                let model = makeModel(linger: 0.05)
                model.pointerIsOverIsland = { false }
                model.showUploadResult(uploaded)
                await t.eventually { model.status == nil }
                t.expectEqual(model.currentState, .collapsed, "closed in the same turn, the tiles never grow in")
            },
            TestCase("the pointer counts against the result it was under, not the taller tiles after") { t in
                let model = makeModel(linger: 0.05)
                // 162 pt down, below the 150 pt result but inside the 174 pt home
                model.pointerIsOverIsland = { model.contentHeight > 162 }
                model.showUploadResult(uploaded)
                await t.eventually { model.status == nil }
                t.expectEqual(model.currentState, .collapsed)
            },
            TestCase("collapse is ignored while a status is pinned") { t in
                let model = makeModel(linger: 0.1)
                model.pointerIsOverIsland = { true }
                model.showUploadResult(uploaded)
                model.collapse()
                t.expectEqual(model.currentState, .expanded)
                await t.eventually { !model.holdsExpanded }
                model.collapse()
                t.expectEqual(model.currentState, .collapsed)
            },
            TestCase("a status arriving while collapsed expands the island") { t in
                let model = makeModel()
                model.parked = true
                model.collapse()
                t.expectEqual(model.currentState, .collapsed)
                model.showUploadResult(uploaded)
                t.expectEqual(model.currentState, .expanded)
                t.expect(!model.parked)
            },
            TestCase("a new result restarts the linger") { t in
                let model = makeModel(linger: 0.3)
                model.showUploadResult(uploaded)
                try await Task.sleep(for: .milliseconds(200))
                model.showUploadResult(uploaded)
                try await Task.sleep(for: .milliseconds(200))
                t.expect(model.status != nil, "the first linger must not clear the second result")
                await t.eventually { model.status == nil }
            },
        ]
    }
}
#endif
