#if DEBUG
import AppKit
import SwiftUI

// the island's shape, screen geometry, what shows when, haptics
enum IslandShellTests: TestSuite {
    static let name = "IslandShell"

    // the 13 inch air's built-in screen
    static let airFrame = NSRect(x: 0, y: 0, width: 1470, height: 956)

    @MainActor
    static func model(destinations list: [Destination] = [CardTests.flowers, CardTests.receipts, CardTests.resumes]) -> IslandViewModel {
        let destinations = DestinationStore()
        destinations.debugUseInMemory(list)
        let model = IslandViewModel(driveService: FakeCardDrive(), destinationStore: destinations,
                                    classifier: DestinationClassifier(store: LearningStore(fileURL: nil)), extractor: FeatureExtractor())
        model.islandScreen = IslandScreen(frame: airFrame, safeTop: 32, leftArea: 646, rightArea: 645, menuBarHeight: 38)
        return model
    }

    static var tests: [TestCase] {
        [
            TestCase("the notch comes from the screen") { t in
                let screen = IslandScreen(frame: airFrame, safeTop: 32, leftArea: 646, rightArea: 645, menuBarHeight: 38)
                t.expect(screen.hasNotch)
                t.expectEqual(screen.notch, CGSize(width: 179, height: 32))
                t.expectEqual(screen.notchCenterX, 735.5)
                let frame = screen.windowFrame(size: CGSize(width: 400, height: 276), overhang: 10)
                t.expectEqual(frame.maxY, 966, "top sits 10 pt above the screen")
                t.expectEqual(frame.midX, 735.5, "centered on the notch")
            },
            TestCase("a screen without a notch gets a hover zone, positioned by its origin") { t in
                // an external display left of the laptop, menu bar on it
                let frame = NSRect(x: -1920, y: 120, width: 1920, height: 1080)
                let screen = IslandScreen(frame: frame, safeTop: 0, leftArea: nil, rightArea: nil, menuBarHeight: 25)
                t.expect(!screen.hasNotch)
                t.expectEqual(screen.notch, CGSize(width: IslandScreen.plainZoneWidth, height: 25))
                t.expectEqual(screen.notchCenterX, -960)
                let window = screen.windowFrame(size: CGSize(width: 400, height: 276), overhang: 10)
                t.expectEqual(window.minX, -1160)
                t.expectEqual(window.maxY, 1210)
                // a hidden menu bar still leaves something to hover
                let hidden = IslandScreen(frame: frame, safeTop: 0, leftArea: nil, rightArea: nil, menuBarHeight: 0)
                t.expectEqual(hidden.notch.height, 24)
            },
            TestCase("the shape's numbers all animate") { t in
                var shape = IslandShape(metrics: IslandMetrics(width: 179, height: 32, bottomRadius: 10, earRadius: 0))
                var data = shape.animatableData
                data.first.first = 380
                data.first.second = 174
                data.second.first = 24
                data.second.second = 6
                shape.animatableData = data
                t.expectEqual(shape.metrics, IslandMetrics(width: 380, height: 174, bottomRadius: 24, earRadius: 6))
            },
            TestCase("the shape hangs from the top, centered, ears outside the body") { t in
                let rect = CGRect(x: 0, y: 0, width: 400, height: 256)
                let notch = IslandShape(metrics: IslandMetrics(width: 179, height: 32, bottomRadius: 10, earRadius: 0)).path(in: rect).boundingRect
                t.expect(abs(notch.minX - 110.5) < 0.01 && abs(notch.width - 179) < 0.01, "\(notch)")
                t.expect(abs(notch.minY) < 0.01 && abs(notch.height - 32) < 0.01, "\(notch)")
                let open = IslandShape(metrics: IslandMetrics(width: 380, height: 174, bottomRadius: 24, earRadius: 6)).path(in: rect).boundingRect
                t.expect(abs(open.width - 392) < 0.01 && abs(open.height - 174) < 0.01, "\(open)")
                t.expect(abs(open.midX - 200) < 0.01, "\(open)")
                // nothing to draw on a screen without a notch
                t.expect(IslandShape(metrics: IslandMetrics(width: 200, height: 0, bottomRadius: 10, earRadius: 0)).path(in: rect).isEmpty)
            },
            TestCase("what shows: drop zone, then card, status, then the surface") { t in
                let model = model()
                model.expand()
                t.expectEqual(model.content, .home)
                model.show(.activity)
                t.expectEqual(model.content, .activity)
                model.timing.resultLinger = 60
                model.showUploadResult(IslandStatus(kind: .success, message: "Uploaded to My Drive"))
                t.expectEqual(model.content, .status)
                model.cardState = .suggesting
                t.expectEqual(model.content, .card)
                model.fileDragChanged(true)
                t.expectEqual(model.content, .dropZone)
                model.fileDragChanged(false)
                await t.eventually("the drop zone goes a moment after the drag") { model.content == .card }
                model.cardState = .idle
                model.debugResetStatus()
                t.expectEqual(model.content, .activity)
            },
            TestCase("a cancelled drag closes from the drop zone, home doesn't show first") { t in
                let model = model()
                model.expand(fromDrag: true)
                model.fileDragChanged(true)
                t.expectEqual(model.content, .dropZone)
                model.fileDragChanged(false)
                await t.eventually("the drop zone goes") { !model.showsDropZone }
                t.expectEqual(model.currentState, .collapsed, "closed before the drop zone went")
                // ended away and hovered open again before the drop zone went, home shows and stays
                model.expand(fromDrag: true)
                model.fileDragChanged(true)
                model.fileDragChanged(false)
                model.collapse()
                model.expand()
                t.expectEqual(model.content, .home)
                try? await Task.sleep(for: .milliseconds(400))
                t.expect(model.isExpanded, "the cancelled drag doesn't close it afterwards")
                // with a card under it, the card comes back and the island stays open
                model.expand()
                model.cardState = .suggesting
                model.fileDragChanged(true)
                model.fileDragChanged(false)
                await t.eventually("the drop zone goes") { !model.showsDropZone }
                t.expect(model.isExpanded && model.content == .card, "the card is back")
            },
            TestCase("heights follow what's showing") { t in
                let model = model()
                t.expectEqual(model.metrics, model.collapsedMetrics)
                t.expectEqual(model.metrics.height, 32)
                model.expand()
                t.expectEqual(model.metrics.height, DesignConstants.homeHeight)
                t.expectEqual(model.metrics.width, DesignConstants.expandedWidth)
                model.show(.storage)
                t.expectEqual(model.metrics.height, DesignConstants.expandedHeight)
                model.show(.home)
                model.cardState = .classifying
                t.expectEqual(model.metrics.height, DesignConstants.singleCardHeight, "a drop still loading")
                model.suggestions = [FileSuggestion(file: FileItem(url: URL(fileURLWithPath: "/tmp/a.pdf")))]
                model.suggestions[0].status = .ready
                model.suggestions[0].level = .confident
                model.cardState = .suggesting
                t.expectEqual(model.metrics.height, DesignConstants.singleCardHeight)
                model.suggestions.append(FileSuggestion(file: FileItem(url: URL(fileURLWithPath: "/tmp/b.pdf"))))
                t.expectEqual(model.metrics.height, DesignConstants.expandedHeight)
                model.cardState = .sent(batchId: UUID())
                t.expectEqual(model.metrics.height, DesignConstants.statusHeight)
                // save to mac turns every row to converting at once, they're listed and counted
                model.suggestions[0].status = .converting
                model.suggestions[1].status = .converting
                model.cardState = .sending
                t.expectEqual(model.metrics.height, DesignConstants.expandedHeight, "converting rows are listed too")
                model.cardState = .idle
                model.suggestions = []
                // a plain screen draws nothing when closed
                model.islandScreen = IslandScreen(frame: airFrame, safeTop: 0, leftArea: nil, rightArea: nil, menuBarHeight: 24)
                model.collapse()
                t.expectEqual(model.metrics.height, 0)
                t.expectEqual(model.metrics.width, IslandScreen.plainZoneWidth)
            },
            TestCase("the shape opens alone, the content mounts a moment later, a quick close cancels it") { t in
                let model = model()
                model.expand()
                t.expect(!model.contentMounted, "the shape commits alone")
                await t.eventually { model.contentMounted }
                model.collapse()
                t.expect(!model.contentMounted, "it leaves with the close")
                model.expand()
                let pending = model.debugMountTask
                model.collapse()
                t.expect(pending?.isCancelled == true, "a close before it mounted cancels it")
                try? await Task.sleep(for: .seconds(model.contentLag * 4))
                t.expect(!model.contentMounted, "and it never mounts")
                model.expand()
                model.expand()
                await t.eventually { model.contentMounted }
            },
            TestCase("the activity tile counts this week, the storage tile shows what's free") { t in
                let storage = StorageStatus(defaults: nil) { ActivityTests.about }
                let model = IslandViewModel(driveService: FakeCardDrive(), storage: storage)
                t.expectEqual(model.tileContent(.activity), TileContent(value: nil, caption: "No sends yet"))
                model.activity.record([ActivityTests.entry("a"), ActivityTests.entry("b"), ActivityTests.entry("old", daysAgo: 20)])
                t.expectEqual(model.tileContent(.activity), TileContent(value: "2", caption: "this week"))
                t.expectEqual(model.tileContent(.storage), TileContent(value: "–", caption: "Checking…", ring: nil, dimmed: true))
                let offline = StorageStatus(defaults: nil) { throw DriveError(category: .offline) }
                let signedOut = StorageStatus(defaults: nil) { throw DriveError.notSignedIn }
                let busy = StorageStatus(defaults: nil) { throw DriveError(category: .server, status: 503) }
                for status in [offline, signedOut, busy] {
                    status.refresh(reason: "test")
                }
                await t.eventually { offline.isStale && signedOut.isStale && busy.isStale }
                t.expectEqual(IslandViewModel(driveService: FakeCardDrive(), storage: offline).tileContent(.storage).caption, "Offline")
                t.expectEqual(IslandViewModel(driveService: FakeCardDrive(), storage: signedOut).tileContent(.storage).caption, "Signed out")
                t.expectEqual(IslandViewModel(driveService: FakeCardDrive(), storage: busy).tileContent(.storage).caption, "Can't check")
                storage.refresh(reason: "test")
                await t.eventually { storage.about != nil }
                let tile = model.tileContent(.storage)
                // google counts quota in 1024s, its 15 GB plan is 15 GiB
                t.expectEqual(StorageText.quota(16_106_127_360), "15 GB")
                t.expectEqual(tile.value, StorageText.quota(16_106_127_360 - 10_737_418_240))
                t.expectEqual(tile.value, "5 GB")
                t.expectEqual(tile.caption, "free")
                t.expect(abs((tile.ring ?? 0) - 10_737_418_240.0 / 16_106_127_360.0) < 1e-9, "\(tile.ring ?? -1)")
                t.expect(!tile.dimmed)
            },
            TestCase("opening refreshes storage only once it's older than 10 minutes") { t in
                var clock = Date()
                var calls = 0
                let storage = StorageStatus(defaults: nil, now: { clock }) {
                    calls += 1
                    return ActivityTests.about
                }
                let model = IslandViewModel(driveService: FakeCardDrive(), storage: storage)
                model.expand()
                await t.eventually { calls == 1 && storage.about != nil }
                model.collapse()
                model.expand()
                try? await Task.sleep(for: .milliseconds(30))
                t.expectEqual(calls, 1, "fresh, not asked again")
                clock = clock.addingTimeInterval(11 * 60)
                try? await Task.sleep(for: .milliseconds(30))
                t.expectEqual(calls, 1, "nothing refreshes on its own")
                model.collapse()
                model.expand()
                await t.eventually { calls == 2 }
            },
            TestCase("a panel left open starts over at home next time") { t in
                let model = model()
                model.show(.activity)
                t.expectEqual(model.currentState, .expanded, "a panel opens the island")
                model.collapse()
                t.expectEqual(model.surface, .activity, "kept while it fades out")
                model.expand()
                t.expectEqual(model.content, .home)
            },
            TestCase("the settings tile opens settings and closes the island") { t in
                let model = model()
                model.expand()
                var posted = 0
                let observer = NotificationCenter.default.addObserver(forName: .showSettings, object: nil, queue: nil) { _ in
                    posted += 1
                }
                defer { NotificationCenter.default.removeObserver(observer) }
                model.tileTapped(.settings)
                t.expectEqual(posted, 1)
                t.expectEqual(model.currentState, .collapsed)
                model.tileTapped(.activity)
                t.expectEqual(model.content, .activity)
                t.expectEqual(model.currentState, .expanded)
            },
            TestCase("a drop taps the trackpad, unless haptics are off") { t in
                let s = try CardTests.setup(t)
                Haptics.performed = []
                Haptics.enabledOverride = true
                defer { Haptics.enabledOverride = nil }
                s.model.handleDrop(CardTests.providers([try CardTests.receiptFile(s.dir)]))
                t.expectEqual(Haptics.performed, [.alignment])
                s.model.clearCard()
                Haptics.enabledOverride = false
                s.model.handleDrop(CardTests.providers([try CardTests.receiptFile(s.dir, "b.txt")]))
                t.expectEqual(Haptics.performed, [.alignment], "no second tap")
                s.model.clearCard()
            },
            TestCase("just upload: a zip that can't be made keeps the files and says so") { t in
                let s = try CardTests.setup(t)
                let a = try CardTests.receiptFile(s.dir, "a.txt")
                let b = try CardTests.receiptFile(s.dir, "b.txt")
                await CardTests.dropAndWait(t, s, [a, b])
                try FileManager.default.removeItem(at: b)
                s.model.justUpload()
                await t.eventually { s.model.cardState == .suggesting && s.model.cardNote != nil }
                t.expectEqual(s.model.suggestions.count, 2, "both files stay on the card")
                t.expect(s.drive.uploads.isEmpty)
                t.expect(s.model.cardNote?.hasPrefix("Couldn't upload") == true, s.model.cardNote ?? "-")
            },
            TestCase("just upload clicked twice uploads once") { t in
                let s = try CardTests.setup(t)
                await CardTests.dropAndWait(t, s, [try CardTests.receiptFile(s.dir)])
                s.drive.hold = true
                s.model.justUpload()
                s.model.justUpload()
                await t.eventually { s.drive.isWaiting }
                t.expectEqual(s.drive.uploadCalls, 1, "the second click started nothing")
                s.drive.release()
                await t.eventually { s.model.cardState == .idle }
                t.expectEqual(s.drive.uploadCalls, 1)
                t.expectEqual(s.drive.uploads.count, 1)
            },
        ]
    }
}
#endif
