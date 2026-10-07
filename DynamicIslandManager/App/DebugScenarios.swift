#if DEBUG
import AppKit
import SwiftUI

// scripted checks on the real running app (signed build, real sign-in, real drive)
// saves snapshots of the island, instead of clicking through by hand
//   DynamicIslandManager --debug-scenario <name>[,<name>...] [--scenario-out <dir>]
// names: hover, hover-behavior, upload-success, upload-offline, auth-expired, setup-window, names-follow-drive, card-*,
// tiles, shapes, display-change, activity, storage, copy-link, convert-*, settings, keys, motion-*, bodies, all
// outside all, idle, drop-timing and demo (the readme recording)
// two launches with the same --scenario-out, card-hint,learning-write (quits normally), then
// learning-read,card-hint-relaunch,cleanup-scratch with --keep-scratch, learning-read first since each reset clears what was learned
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

    // and keep their activity in a temp file
    nonisolated static var activityFileURL: URL? {
        guard isScenarioRun else { return nil }
        return URL(fileURLWithPath: NSTemporaryDirectory() + "dim-scn/activity.json")
    }

    // the scratch domain as it is, without starting it over
    nonisolated static var scratchDefaults: UserDefaults? {
        guard isScenarioRun else { return nil }
        return UserDefaults(suiteName: scratchDomain)
    }

    // destinations go in a scratch defaults domain copied from the real list
    // so hints and removals really save but never touch the real one
    // --keep-scratch (relaunch) starts from what the last run saved
    nonisolated static let scratchDomain = "DynamicIslandManager.scenarios"
    // what the settings window writes, each run and each scenario start from the defaults
    nonisolated static let settingsKeys = [ConvertDefaults.heicKey, ConvertDefaults.audioKey, ConvertDefaults.movieKey,
                                           Haptics.defaultsKey, AppDefaults.settingsPaneKey]

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
            if let url = activityFileURL {
                try? FileManager.default.removeItem(at: url)
            }
            for key in settingsKeys {
                scratch.removeObject(forKey: key)
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

        // links are logged, never opened in a browser
        LinkActions.logOnly = true
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

// passes drive calls on, counts and refuses uploads so a check can't leave one in drive
final class NoUploads: DriveTransport, @unchecked Sendable {
    let inner: DriveTransport
    private let lock = NSLock()
    private var tried = 0

    init(_ inner: DriveTransport) {
        self.inner = inner
    }

    var attempts: Int { lock.withLock { tried } }

    // multipart, resumable starts and chunks all go to /upload/
    private func refuse(_ request: URLRequest) throws {
        guard request.url?.path.hasPrefix("/upload/") == true else { return }
        lock.withLock { tried += 1 }
        throw DriveError.refused("no uploads in this check")
    }

    func send(_ request: URLRequest, bodyFile: URL?) async throws -> (Data, HTTPURLResponse) {
        try refuse(request)
        return try await inner.send(request, bodyFile: bodyFile)
    }

    func send(_ request: URLRequest, body: Data, progress: (@Sendable (Int64) -> Void)?) async throws -> (Data, HTTPURLResponse) {
        try refuse(request)
        return try await inner.send(request, body: body, progress: progress)
    }

    func send(_ request: URLRequest, bodyFile: URL, progress: (@Sendable (Int64) -> Void)?) async throws -> (Data, HTTPURLResponse) {
        try refuse(request)
        return try await inner.send(request, bodyFile: bodyFile, progress: progress)
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
    // the user's app, scenarios that bring this one forward hand it back
    let frontAtStart: NSRunningApplication?

    init(app: AppDelegate, outDir: URL) {
        self.app = app
        self.outDir = outDir
        let front = NSWorkspace.shared.frontmostApplication
        frontAtStart = front == NSRunningApplication.current ? nil : front
    }

    var model: IslandViewModel { app.islandViewModel! }
    var window: DynamicIslandWindow { app.window! }
    var drive: GoogleDriveService { app.driveViewModel.driveService }

    func run(_ names: [String]) async -> Int32 {
        guard app.islandViewModel != nil, app.window != nil else {
            print("no island, sign-in didn't restore")
            return 1
        }
        let all = ["hover", "hover-behavior", "upload-success", "upload-offline", "auth-expired", "setup-window",
                   "names-follow-drive", "card-single", "card-undo-correct", "card-chip", "card-multi", "card-folder", "card-just-upload",
                   "card-dismiss", "card-hold", "card-release", "card-unattended", "card-no-destinations", "card-progress",
                   "tiles", "shapes", "display-change", "activity", "storage", "copy-link", "convert-send", "convert-save", "convert-error",
                   "settings", "keys",
                   "motion", "motion-card", "motion-status", "motion-hover", "motion-mid", "motion-reduced", "bodies"]
        for name in names == ["all"] ? all : names {
            scenario = name
            print("\n== scenario \(name)")
            switch name {
            case "hover": await hover()
            case "upload-success": await uploadSuccess()
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
            case "card-progress": await cardProgress()
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
            case "tiles": await tiles()
            case "shapes": await shapes()
            case "display-change": await displayChange()
            case "motion-reduced": await motionReduced()
            case "idle": await idleRest()
            case "activity": await activity()
            case "storage": await storage()
            case "copy-link": await copyLink()
            case "convert-send": await convertSend()
            case "convert-save": await convertSave()
            case "convert-error": await convertError()
            case "settings": await settings()
            case "keys": await keys()
            case "demo": await demo()
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

    // one file through the card's "Just upload", the result shows ~3 s then the island closes
    private func uploadSuccess() async {
        let item = makeFile("dim-scenario-\(stamp()).txt")
        pointerOutside()
        await dropAndWait([item.url])
        let previous = model.lastUploadedFile?.id
        let start = Date()
        model.justUpload()
        let done = await waitFor(30) { self.model.status?.kind == .success }
        check(done != nil, "Just upload into My Drive works (\(format(Date().timeIntervalSince(start))))")
        let shown = Date()
        check(model.status?.message == "Uploaded to My Drive", "shows \"\(model.status?.message ?? "nothing")\"")
        check(model.cardState == .idle, "the card is gone")
        check(model.holdsExpanded, "the result holds the island open")
        await snapshot("1-result")

        let cleared = await waitFor(5) { self.model.status == nil }
        let clearedAfter = Date().timeIntervalSince(shown)
        check(cleared != nil && clearedAfter > 2.5 && clearedAfter < 4, "result goes away after ~3 s (\(format(clearedAfter)))")
        let collapsed = await waitFor(2) { self.model.currentState == .collapsed }
        check(collapsed != nil, "then the island closes by itself (\(format(Date().timeIntervalSince(shown))) after the result)")

        // delete the test upload
        if let file = model.lastUploadedFile, file.id != previous {
            check(file.name == item.name, "drive returned the uploaded name (\(file.name))")
            pendingDeletes.append(file.id)
        } else {
            check(false, "an upload happened")
        }
    }

    // destinations saved before hints existed still load in settings
    private func setupWindow() async {
        let saved = app.destinationStore.destinations
        print("  \(saved.count) saved destination(s): \(saved.map(\.name).joined(separator: ", "))")
        check(!saved.isEmpty, "saved destinations decoded")
        NotificationCenter.default.post(name: .showDestinationSetup, object: nil)
        let shown = await waitFor(2) { self.app.settingsWindow?.isVisible == true && self.app.settingsWindow?.currentPane == .destinations }
        check(shown != nil, "Settings opens on Destinations")
        if let window = app.settingsWindow {
            // what doesn't scroll is inside the window, a pane bigger than it gets cropped on all sides
            let controls = saved.prefix(1).flatMap { ["remove-\($0.name)", "hint-\($0.name)"] } + ["resetLearning", "done"]
            _ = await waitFor(2) { controls.allSatisfy { DebugFrames.frames[$0] != nil } }
            let visible = NSRect(origin: .zero, size: window.contentLayoutRect.size)
            let outside = controls.filter { !(DebugFrames.frames[$0].map(visible.contains) ?? false) }
            check(outside.isEmpty, "Destinations' fixed controls and first row are inside the window (outside: \(outside))")
            await snapshot("list", of: window)
            window.close()
        }
    }

    // a send that fails offline shows the error on the card, retry with a real click sends it
    private func uploadOffline() async {
        guard let folders = folders() else { return }
        pointerOutside()
        await dropAndWait([makeFile("dim-scenario-offline-\(stamp()).txt").url])
        guard let row = model.suggestions.first else { return }
        // two seconds in flight, then "no internet"
        drive.transport = FaultTransport(mode: .offline, delay: 2)
        model.send(row.id, to: folders.receipts)
        try? await Task.sleep(for: .milliseconds(300))
        check(model.cardState == .sending, "shows progress while sending")
        await snapshot("1-sending")
        // same as hovering out or a text drag in another app
        model.collapse()
        check(model.currentState == .expanded, "stays open during the send")

        let failed = await waitFor(5) {
            if case .error = self.model.cardState { return true }
            return false
        }
        check(failed != nil, "the send fails")
        check(model.cardState == .error("You're offline", retry: .resend), "shows \"You're offline\" with Retry (\(model.cardState))")
        check(model.suggestions.count == 1, "the file is still on the card")
        await snapshot("2-error")
        model.collapse()
        check(model.currentState == .expanded, "the error stays up when something asks to collapse")

        // back online, a real click on Retry
        drive.transport = URLSessionDriveTransport()
        check(await tap("retry"), "clicked Retry")
        let ids = await waitForSent("retry sends it")
        if let id = ids.first {
            let location = await locate(id)
            check(location == .at([folders.receipts.id]), "drive has it in \(folders.receipts.name) (\(location))")
        }
    }

    // signed out mid-send, the card offers sign in again and the window opens
    private func authExpired() async {
        guard let folders = folders() else { return }
        model.timing.unattended = 3
        pointerOutside()
        await dropAndWait([makeFile("dim-scenario-auth-\(stamp()).txt").url])
        guard let row = model.suggestions.first else { return }
        drive.transport = FaultTransport(mode: .status(401), delay: 0.2)
        drive.tokenSource = FaultTokens()
        model.send(row.id, to: folders.receipts)
        let failed = await waitFor(5) {
            if case .error = self.model.cardState { return true }
            return false
        }
        let shownAt = Date()
        check(failed != nil && model.authExpired, "the card says signed out (\(model.cardState))")
        await snapshot("1-card")

        let parked = await waitFor(6) { self.model.parked && self.model.currentState == .collapsed }
        let after = Date().timeIntervalSince(shownAt)
        check(parked != nil && after > 2.8 && after < 4, "an unattended error folds away (\(format(after)), timeout 3 s)")
        // same as hovering the notch
        model.expand()
        try? await Task.sleep(for: .milliseconds(600))
        check(model.currentState == .expanded && model.authExpired && model.holdsExpanded, "hovering brings it back")

        // real click on the button, posted to the island window
        check(await tap("signInAgain"), "clicked \"Sign in again…\"")
        let opened = await waitFor(2) { self.app.signInWindow?.isVisible == true }
        check(opened != nil, "one click opens the sign-in window (\(format(opened)))")
        if let signIn = app.signInWindow {
            check(signIn.styleMask.contains(.titled), "the sign-in window is titled (google's sheet attaches to it)")
            try? await Task.sleep(for: .milliseconds(400))
            await snapshot("2-signin-window", of: signIn)
        }

        // google's sign-in needs a person, so pretend it worked
        drive.transport = URLSessionDriveTransport()
        drive.tokenSource = nil
        drive.isSignedIn = true
        let cleared = await waitFor(2) { !self.model.authExpired }
        check(cleared != nil, "signing in again clears it")
        check(app.signInWindow == nil, "the sign-in window closed")
        let islands = NSApp.windows.filter { $0 is DynamicIslandWindow }.count
        check(islands == 1, "exactly one island window after signing in again (\(islands))")
        // the failed send can go now
        check(await tap("retry"), "clicked Retry")
        _ = await waitForSent("retry after signing in sends it")
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
        app.settingsWindow?.close()
        drive.transport = URLSessionDriveTransport()
        drive.tokenSource = nil
        model.debugResetStatus()
        model.debugReduceMotion = false
        model.timing = IslandViewModel.Timing()
        model.surface = .home
        // settings go back to their defaults, a later scenario mustn't inherit jpeg or haptics off
        for key in DebugScenarios.settingsKeys {
            AppDefaults.shared.removeObject(forKey: key)
        }
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

    // frames count from the top-left of the window's content, below any title bar and toolbar
    // window space is bottom-left
    func windowPoint(_ x: CGFloat, _ y: CGFloat, in window: NSWindow) -> NSPoint? {
        guard window.contentView != nil else { return nil }
        return NSPoint(x: x, y: window.contentLayoutRect.maxY - y)
    }

    // mouse down/up at the control's center through the normal event path
    @discardableResult
    // trailing aims at the end of the frame, where a form row keeps its switch or menu
    func click(_ control: String, in window: NSWindow, trailing: Bool = false) -> Bool {
        guard let frame = DebugFrames.frames[control], let point = windowPoint(trailing ? frame.maxX - 16 : frame.midX, frame.midY, in: window) else {
            print("  no frame for \(control)")
            return false
        }
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
