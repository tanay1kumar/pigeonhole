#if DEBUG
import AppKit
import SwiftUI

// scripted checks on the real running app (signed build, real sign-in, real drive)
// saves snapshots of the island, instead of clicking through by hand
//   DynamicIslandManager --debug-scenario <name>[,<name>...] [--scenario-out <dir>]
// names: hover, upload-success, upload-cube, upload-offline, auth-expired, setup-window, card-*, motion-*, bodies, all
// two launches: card-hint,learning-write (quits normally), then
// card-hint-relaunch,learning-read,cleanup-scratch with --keep-scratch
// same view model calls as the buttons, real drags can't be scripted
@MainActor
enum DebugScenarios {
    nonisolated static var isScenarioRun: Bool {
        CommandLine.arguments.contains("--debug-scenario")
    }

    // scenario runs learn into a temp file, not the real one
    nonisolated static var learningFileURL: URL? {
        guard isScenarioRun else { return nil }
        return URL(fileURLWithPath: NSTemporaryDirectory() + "dim-scn/learning.json")
    }

    // destinations go in a scratch defaults domain copied from the real list
    // so hints and removals really save but never touch the real one
    // --keep-scratch (relaunch) starts from what the last run saved
    nonisolated static let scratchDomain = "DynamicIslandManager.scenarios"

    nonisolated static func prepareScratch() -> UserDefaults? {
        guard isScenarioRun, let scratch = UserDefaults(suiteName: scratchDomain) else { return nil }
        if !CommandLine.arguments.contains("--keep-scratch") {
            scratch.removeObject(forKey: "destinations")
            if let saved = UserDefaults.standard.data(forKey: "destinations") {
                scratch.set(saved, forKey: "destinations")
            }
            if let url = learningFileURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
        return scratch
    }

    static func startIfRequested(app: AppDelegate) {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--debug-scenario"), index + 1 < arguments.count else { return }
        let names = arguments[index + 1].split(separator: ",").map(String.init)
        let outPath = arguments.firstIndex(of: "--scenario-out").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        let outDir = URL(fileURLWithPath: outPath ?? NSTemporaryDirectory() + "dim-scn", isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        Task {
            // let the island view appear first
            try? await Task.sleep(for: .seconds(1.5))
            let runner = ScenarioRunner(app: app, outDir: outDir)
            let code = await runner.run(names)
            // learning-write always quits normally so quitting saves the data
            if runner.quitNormally {
                NSApp.terminate(nil)
            } else {
                exit(code)
            }
        }
    }
}

// fails every request (offline and expired sign-in scenarios)
struct FaultTransport: DriveTransport {
    enum Mode {
        case offline
        case status(Int)
    }

    let mode: Mode
    var delay: Double = 0

    func send(_ request: URLRequest, bodyFile: URL?) async throws -> (Data, HTTPURLResponse) {
        if delay > 0 {
            try await Task.sleep(for: .seconds(delay))
        }
        switch mode {
        case .offline:
            throw URLError(.notConnectedToInternet)
        case .status(let code):
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
        }
    }
}

// dead refresh token, like after revoking the app
struct FaultTokens: DriveTokenSource {
    func accessToken() async throws -> String {
        "scenario-token"
    }

    func forceRefresh() async throws -> String {
        throw NSError(domain: "org.openid.appauth.oauth_token", code: -10,
                      userInfo: [NSLocalizedDescriptionKey: "invalid_grant (simulated)"])
    }
}

@MainActor
final class ScenarioRunner {
    let app: AppDelegate
    let outDir: URL
    private var failures: [String] = []
    private(set) var scenario = ""
    // uploads from scenarios, reset() deletes whatever undo didn't
    var pendingDeletes: [String] = []
    var quitNormally = false

    init(app: AppDelegate, outDir: URL) {
        self.app = app
        self.outDir = outDir
    }

    var model: IslandViewModel { app.islandViewModel! }
    var window: DynamicIslandWindow { app.window! }
    var drive: GoogleDriveService { app.driveViewModel.driveService }

    func run(_ names: [String]) async -> Int32 {
        guard app.islandViewModel != nil, app.window != nil else {
            print("no island, sign-in didn't restore")
            return 1
        }
        let all = ["hover", "hover-behavior", "upload-success", "upload-cube", "upload-offline", "auth-expired", "setup-window",
                   "names-follow-drive", "card-single", "card-undo-correct", "card-chip", "card-multi", "card-folder", "card-just-upload",
                   "card-dismiss", "card-hold", "card-release", "card-unattended", "card-no-destinations",
                   "motion", "motion-card", "motion-status", "motion-hover", "motion-mid", "bodies"]
        for name in names == ["all"] ? all : names {
            scenario = name
            print("\n== scenario \(name)")
            switch name {
            case "hover": await hover()
            case "upload-success": await uploadSuccess()
            case "upload-cube": await uploadCube()
            case "setup-window": await setupWindow()
            case "upload-offline": await uploadOffline()
            case "auth-expired": await authExpired()
            case "names-follow-drive": await namesFollowDrive()
            case "card-single": await cardSingle()
            case "card-undo-correct": await cardUndoCorrect()
            case "card-chip": await cardChip()
            case "card-multi": await cardMulti()
            case "card-folder": await cardFolder()
            case "card-just-upload": await cardJustUpload()
            case "card-dismiss": await cardDismiss()
            case "card-hold": await cardHold()
            case "card-release": await cardRelease()
            case "card-unattended": await cardUnattended()
            case "card-no-destinations": await cardNoDestinations()
            case "card-hint": await cardHint()
            case "card-hint-relaunch": await cardHintRelaunch()
            case "learning-write": await learningWrite()
            case "learning-read": await learningRead()
            case "cleanup-scratch": cleanupScratch()
            case "drop-timing": await dropTiming()
            case "hover-behavior": await hoverBehavior()
            case "motion": await motion("home")
            case "motion-card": await motion("card")
            case "motion-status": await motion("status")
            case "motion-hover": await motionHover()
            case "motion-mid": await motionMid()
            case "bodies": await bodies()
            default:
                print("unknown scenario \(name)")
                return 2
            }
            // quit right away so the save on quit has to keep the learned data
            if quitNormally {
                break
            }
            await reset()
        }
        if failures.isEmpty {
            print("\nSCENARIOS PASS")
            return 0
        }
        print("\nSCENARIOS FAIL (\(failures.count)):\n  " + failures.joined(separator: "\n  "))
        return 1
    }

    // MARK: scenarios

    // hover logic, warps the real cursor around the notch
    private func hover() async {
        // don't move the real cursor while someone is using the mac
        guard secondsSinceUserInput() >= 20 else {
            print("  skip: someone used the mouse or keyboard in the last 20 s, not moving the cursor")
            return
        }
        let original = NSEvent.mouseLocation
        let pill = window.pillFrame
        model.collapse()
        _ = await waitFor(1) { self.model.currentState == .collapsed }

        warp(to: NSPoint(x: pill.midX, y: pill.midY))
        try? await Task.sleep(for: .milliseconds(50))
        guard pill.contains(NSEvent.mouseLocation) else {
            print("  skip: warping the cursor didn't move it")
            warp(to: original)
            return
        }
        let expanded = await waitFor(1) { self.model.currentState == .expanded }
        check(expanded != nil, "hovering the notch expands the island (\(format(expanded)))")
        // the window follows the view one update later
        let takesClicks = await waitFor(1) { !self.window.ignoresMouseEvents }
        check(takesClicks != nil, "expanded island takes clicks")
        await snapshot("expanded")

        warp(to: NSPoint(x: window.islandFrame.midX, y: window.islandFrame.minY + 40))
        try? await Task.sleep(for: .milliseconds(800))
        check(model.currentState == .expanded, "stays open while the pointer is inside")

        let screen = NSScreen.screens.first?.frame ?? .zero
        warp(to: NSPoint(x: screen.minX + 200, y: screen.midY))
        let collapsed = await waitFor(1.5) { self.model.currentState == .collapsed }
        check(collapsed != nil, "moving away collapses it (\(format(collapsed)))")
        let clickThrough = await waitFor(1) { self.window.ignoresMouseEvents }
        check(clickThrough != nil, "collapsed island lets clicks through (\(format(clickThrough)))")
        warp(to: original)
    }

    private func uploadSuccess() async {
        let item = makeFile("dim-scenario-\(stamp()).txt")
        model.addFiles([item])
        model.expand()
        try? await Task.sleep(for: .milliseconds(600))
        await snapshot("1-queued")
        let pointerAway = !pointerOverIsland
        print("  pointer is \(pointerAway ? "away from" : "over") the island")

        let start = Date()
        let ok = await model.uploadDroppedFiles()
        check(ok, "upload into My Drive works (\(format(Date().timeIntervalSince(start))))")
        let shown = Date()
        check(model.status?.kind == .success, "shows success: \(model.status?.message ?? "nothing")")
        check(model.droppedFiles.isEmpty, "queue cleared after success")
        check(model.holdsExpanded, "the result holds the island open")
        try? await Task.sleep(for: .milliseconds(500))
        await snapshot("2-result")

        let cleared = await waitFor(5) { self.model.status == nil }
        let clearedAfter = Date().timeIntervalSince(shown)
        check(cleared != nil && clearedAfter > 2.5 && clearedAfter < 4, "result goes away after ~3 s (\(format(clearedAfter)))")
        if pointerAway {
            let collapsed = await waitFor(2) { self.model.currentState == .collapsed }
            check(collapsed != nil, "then the island closes by itself (\(format(Date().timeIntervalSince(shown))) after the result)")
        }

        // delete the test upload
        if let file = model.lastUploadedFile {
            check(file.name == item.name, "drive returned the uploaded name (\(file.name))")
            do {
                try await drive.deleteFile(id: file.id, protectedIds: Set(app.destinationStore.destinations.map(\.id)))
                check(true, "deleted the test upload \(file.id)")
            } catch {
                check(false, "delete the test upload: \(error.localizedDescription)")
            }
        }
    }

    // destinations saved before hints existed still load in the setup window
    private func setupWindow() async {
        let saved = app.destinationStore.destinations
        print("  \(saved.count) saved destination(s): \(saved.map(\.name).joined(separator: ", "))")
        check(!saved.isEmpty, "saved destinations decoded")
        NotificationCenter.default.post(name: .showDestinationSetup, object: nil)
        let shown = await waitFor(2) { self.app.destinationsWindow?.isVisible == true }
        check(shown != nil, "the Destinations window opens")
        if let window = app.destinationsWindow {
            await snapshot("list", of: window)
            window.close()
        }
    }

    // two files + a real click on the upload cube, zipped into one upload
    private func uploadCube() async {
        // pretend the pointer is inside so the island stays open for the click
        DebugPointer.override = NSPoint(x: window.islandFrame.midX, y: window.islandFrame.minY + 40)
        defer { DebugPointer.override = nil }
        model.expand()
        model.addFiles([makeFile("dim-scenario-a.txt"), makeFile("dim-scenario-b.txt")])
        let gridReady = await waitFor(2) { DebugFrames.frames["cube-upload"] != nil && self.model.currentState == .expanded }
        check(gridReady != nil, "the cube grid is showing")
        // wait for the expand animation so the cubes stop moving
        try? await Task.sleep(for: .milliseconds(600))
        await snapshot("1-grid")

        let clicked = click("cube-upload", in: window)
        check(clicked, "clicked the Upload cube once")
        let started = await waitFor(2) { self.model.isUploading || self.model.status != nil }
        check(started != nil, "the tap started the upload (\(model.status?.message ?? "no status"))")
        let finished = await waitFor(30) { !self.model.isUploading && self.model.status?.kind != .working }
        check(finished != nil && model.status?.kind == .success, "zip uploaded to My Drive (\(model.status?.message ?? "no status"))")
        await snapshot("2-result")
        if let file = model.lastUploadedFile {
            check(file.name.hasPrefix("files_") && file.name.hasSuffix(".zip"), "one zip went up: \(file.name), \(file.mimeType ?? "-")")
            check(model.droppedFiles.isEmpty, "queue cleared")
            try? await drive.deleteFile(id: file.id, protectedIds: Set(app.destinationStore.destinations.map(\.id)))
            print("  deleted the test zip \(file.id)")
        }
        let cleared = await waitFor(5) { self.model.status == nil }
        check(cleared != nil, "result clears")
        check(model.currentState == .expanded, "stays open while the pointer is inside")
        DebugPointer.override = nil
        let collapsed = await waitFor(2) { self.model.currentState == .collapsed }
        check(collapsed != nil, "closes once the pointer is gone (\(format(collapsed)))")
    }

    private func uploadOffline() async {
        // two seconds in flight, then "no internet"
        drive.transport = FaultTransport(mode: .offline, delay: 2)
        model.addFiles([makeFile("dim-scenario-offline.txt")])
        model.expand()
        try? await Task.sleep(for: .milliseconds(500))
        let pointerAway = !pointerOverIsland

        let upload = Task { await model.uploadDroppedFiles() }
        try? await Task.sleep(for: .milliseconds(300))
        check(model.status?.kind == .working, "shows progress while uploading (\(model.status?.message ?? "nothing"))")
        await snapshot("1-uploading")
        // same as hovering out or a text drag in another app
        model.collapse()
        check(model.currentState == .expanded, "stays open during the upload")

        let ok = await upload.value
        let errorShown = Date()
        check(!ok, "upload reports failure")
        check(model.status == IslandStatus(kind: .failure, message: "You're offline"), "shows \"You're offline\" (\(model.status?.message ?? "nothing"))")
        check(model.droppedFiles.count == 1, "file still queued for a retry")
        check(model.currentState == .expanded, "the error is on screen")
        await snapshot("2-error")
        model.collapse()
        check(model.currentState == .expanded, "the error stays up when something asks to collapse")

        let unpinned = await waitFor(5) { !self.model.statusPinned }
        check(unpinned != nil, "the error lets go after ~3 s (\(format(Date().timeIntervalSince(errorShown))))")
        if pointerAway {
            let collapsed = await waitFor(2) { self.model.currentState == .collapsed }
            let total = Date().timeIntervalSince(errorShown)
            check(collapsed != nil && total > 2.8 && total < 4.5, "island closes by itself ~3 s after the error, pointer never came back (\(format(total)))")
        }
        check(model.droppedFiles.count == 1, "file still queued afterwards")
    }

    private func authExpired() async {
        drive.transport = FaultTransport(mode: .status(401), delay: 0.2)
        drive.tokenSource = FaultTokens()
        model.timing.unattended = 3
        model.addFiles([makeFile("dim-scenario-auth.txt")])
        model.expand()
        try? await Task.sleep(for: .milliseconds(500))

        let ok = await model.uploadDroppedFiles()
        let bannerShown = Date()
        check(!ok, "upload reports failure")
        check(model.authExpired && model.status?.kind == .signIn, "shows the sign-in banner (\(model.status?.message ?? "nothing"))")
        check(model.droppedFiles.count == 1, "file still queued")
        try? await Task.sleep(for: .milliseconds(500))
        await snapshot("1-banner")

        if !pointerOverIsland {
            let parked = await waitFor(6) { self.model.parked && self.model.currentState == .collapsed }
            let after = Date().timeIntervalSince(bannerShown)
            check(parked != nil && after > 2.8 && after < 4, "an unattended banner folds away (\(format(after)) after it appeared, timeout 3 s)")
            check(model.status?.kind == .signIn, "the banner is kept while folded")
            // same as hovering the notch
            model.expand()
            try? await Task.sleep(for: .milliseconds(600))
            check(model.currentState == .expanded && model.status?.kind == .signIn && model.holdsExpanded, "hovering brings the banner back")
            await snapshot("2-back")
        } else {
            try? await Task.sleep(for: .seconds(3.5))
            check(model.status?.kind == .signIn, "the banner doesn't auto-dismiss")
        }

        // real click on the button, posted to the island window
        let clicked = click("signInAgain", in: window)
        check(clicked, "found the \"Sign in again\" button and clicked it once")
        let opened = await waitFor(2) { self.app.signInWindow?.isVisible == true }
        check(opened != nil, "one click on \"Sign in again\" opens the Sign In window (\(format(opened)))")
        if let signIn = app.signInWindow {
            check(signIn.styleMask.contains(.titled), "the sign-in window is titled (google's sheet attaches to it)")
            try? await Task.sleep(for: .milliseconds(400))
            await snapshot("3-signin-window", of: signIn)
        }

        // google's sign-in needs a person, so pretend it worked
        drive.transport = URLSessionDriveTransport()
        drive.tokenSource = nil
        drive.isSignedIn = true
        let cleared = await waitFor(2) { self.model.status == nil && !self.model.authExpired }
        check(cleared != nil, "the banner clears when sign-in succeeds")
        check(app.signInWindow == nil, "the sign-in window closed")
        let islands = NSApp.windows.filter { $0 is DynamicIslandWindow }.count
        check(islands == 1, "exactly one island window after signing in again (\(islands))")
    }

    // MARK: helpers

    private func reset() async {
        DebugPointer.override = nil
        DebugHooks.dragMonitor?.isDraggingFiles = false
        DebugHooks.dragMonitor?.isDraggingAnything = false
        model.clearCard()
        await deletePendingUploads()
        // each scenario starts with nothing learned (temp file only)
        if let store = app.learningStore, store.fileURL != nil, store.fileURL == DebugScenarios.learningFileURL {
            await app.classifier?.reset()
        }
        app.destinationsWindow?.close()
        drive.transport = URLSessionDriveTransport()
        drive.tokenSource = nil
        model.debugResetStatus()
        model.timing = IslandViewModel.Timing()
        model.clearFiles()
        app.signInWindow?.close()
        try? await Task.sleep(for: .milliseconds(300))
    }

    func check(_ condition: Bool, _ what: String) {
        print(condition ? "  ok   \(what)" : "  FAIL \(what)")
        if !condition {
            failures.append("\(scenario): \(what)")
        }
    }

    // seconds until condition held, nil on timeout
    func waitFor(_ timeout: Double, _ condition: () -> Bool) async -> Double? {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if condition() { return Date().timeIntervalSince(start) }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition() ? Date().timeIntervalSince(start) : nil
    }

    func format(_ seconds: Double?) -> String {
        guard let seconds else { return "timed out" }
        return String(format: "%.2f s", seconds)
    }

    private var pointerOverIsland: Bool {
        window.islandFrame.contains(NSEvent.mouseLocation)
    }

    // last time a person touched the mouse or keyboard
    func secondsSinceUserInput() -> Double {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown, .leftMouseDragged]
        return types.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? 0
    }

    // appkit is bottom-left based, cg is top-left of the main display
    private func warp(to point: NSPoint) {
        let height = NSScreen.screens.first?.frame.maxY ?? 0
        CGWarpMouseCursorPosition(CGPoint(x: point.x, y: height - point.y))
        // warping sends no mouse event, so post one into the app for hover's local monitor
        // (the global monitor only sees real moves)
        if let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                          context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
            NSApp.postEvent(event, atStart: false)
        }
    }

    private func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HHmmss"
        return formatter.string(from: Date())
    }

    private func makeFile(_ name: String) -> FileItem {
        let url = outDir.appendingPathComponent(name)
        try? Data("dynamic island scenario test file, safe to delete\n".utf8).write(to: url)
        return FileItem(url: url)
    }

    func snapshot(_ label: String, of target: NSWindow? = nil) async {
        // let swiftui finish its transition first
        try? await Task.sleep(for: .milliseconds(600))
        let source = target ?? window
        guard let view = source.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        // window background isn't part of the view, paint one so text shows
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        // use the window's appearance or dark mode text ends up on a light background
        source.effectiveAppearance.performAsCurrentDrawingAppearance {
            (target == nil ? NSColor(white: 0.45, alpha: 1) : NSColor.windowBackgroundColor).setFill()
            NSRect(origin: .zero, size: view.bounds.size).fill()
        }
        // source-over, plain draw(in:) copies transparent pixels too
        rep.draw(in: NSRect(origin: .zero, size: view.bounds.size), from: .zero, operation: .sourceOver,
                 fraction: 1, respectFlipped: true, hints: nil)
        image.unlockFocus()
        let url = outDir.appendingPathComponent("\(scenario)-\(label).png")
        if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) {
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
        print("  snap \(url.path)")
    }

    // mouse down/up at the control's center through the normal event path
    @discardableResult
    func click(_ control: String, in window: NSWindow) -> Bool {
        guard let frame = DebugFrames.frames[control], window.contentView != nil else {
            print("  no frame for \(control)")
            return false
        }
        // swiftui global space is top-left and includes the title bar
        // window space is bottom-left
        let point = NSPoint(x: frame.midX, y: window.frame.height - frame.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil,
                                                 eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { return false }
            NSApp.postEvent(event, atStart: false)
        }
        return true
    }
}
#endif
