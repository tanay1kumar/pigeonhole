#if DEBUG
import AppKit
import SwiftUI

// drives the real running app (signed build, real sign-in, real island, real drive) through
// scripted flows and snapshots the island, for checks a person would otherwise do by hand:
//   DynamicIslandManager --debug-scenario <name>[,<name>...] [--scenario-out <dir>]
// names: hover, upload-success, upload-offline, auth-expired, all
// it calls the same view model methods the buttons do; real mouse drags can't be scripted from here.
@MainActor
enum DebugScenarios {
    static func startIfRequested(app: AppDelegate) {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--debug-scenario"), index + 1 < arguments.count else { return }
        let names = arguments[index + 1].split(separator: ",").map(String.init)
        let outPath = arguments.firstIndex(of: "--scenario-out").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        let outDir = URL(fileURLWithPath: outPath ?? NSTemporaryDirectory() + "dim-scn", isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        Task {
            // let the island's view appear and its timers start
            try? await Task.sleep(for: .seconds(1.5))
            let runner = ScenarioRunner(app: app, outDir: outDir)
            exit(await runner.run(names))
        }
    }
}

// fails every request, for offline and expired-sign-in scenarios
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

// a sign-in whose refresh token is dead, like after revoking the app
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
    private let app: AppDelegate
    private let outDir: URL
    private var failures: [String] = []
    private var scenario = ""

    init(app: AppDelegate, outDir: URL) {
        self.app = app
        self.outDir = outDir
    }

    private var model: IslandViewModel { app.islandViewModel! }
    private var window: DynamicIslandWindow { app.window! }
    private var drive: GoogleDriveService { app.driveViewModel.driveService }

    func run(_ names: [String]) async -> Int32 {
        guard app.islandViewModel != nil, app.window != nil else {
            print("no island, sign-in didn't restore")
            return 1
        }
        let all = ["hover", "upload-success", "upload-cube", "upload-offline", "auth-expired", "setup-window"]
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
            default:
                print("unknown scenario \(name)")
                return 2
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

    // the polling hover logic, with the real cursor warped around the notch
    private func hover() async {
        // moving the real cursor would get in the way of someone using the mac
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

        // tidy up the test upload
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

    // saved destinations (made before hints existed) still load and show in the setup window
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

    // two files, a real click on the upload cube: zipped into one upload to my drive
    private func uploadCube() async {
        // pretend the pointer is inside so the island stays open for the click
        DebugPointer.override = NSPoint(x: window.islandFrame.midX, y: window.islandFrame.minY + 40)
        defer { DebugPointer.override = nil }
        model.expand()
        model.addFiles([makeFile("dim-scenario-a.txt"), makeFile("dim-scenario-b.txt")])
        let gridReady = await waitFor(2) { DebugFrames.frames["cube-upload"] != nil && self.model.currentState == .expanded }
        check(gridReady != nil, "the cube grid is showing")
        // the expand animation has to settle before the cubes sit still
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
        // what hovering out, or a text drag in another app, asks for
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
            // what hovering the notch does
            model.expand()
            try? await Task.sleep(for: .milliseconds(600))
            check(model.currentState == .expanded && model.status?.kind == .signIn && model.holdsExpanded, "hovering brings the banner back")
            await snapshot("2-back")
        } else {
            try? await Task.sleep(for: .seconds(3.5))
            check(model.status?.kind == .signIn, "the banner doesn't auto-dismiss")
        }

        // one real click on the button, posted to the island window like a mouse would
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
        drive.transport = URLSessionDriveTransport()
        drive.tokenSource = nil
        model.debugResetStatus()
        model.timing = IslandViewModel.Timing()
        model.clearFiles()
        app.signInWindow?.close()
        try? await Task.sleep(for: .milliseconds(300))
    }

    private func check(_ condition: Bool, _ what: String) {
        print(condition ? "  ok   \(what)" : "  FAIL \(what)")
        if !condition {
            failures.append("\(scenario): \(what)")
        }
    }

    // seconds until condition held, nil on timeout
    private func waitFor(_ timeout: Double, _ condition: () -> Bool) async -> Double? {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if condition() { return Date().timeIntervalSince(start) }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition() ? Date().timeIntervalSince(start) : nil
    }

    private func format(_ seconds: Double?) -> String {
        guard let seconds else { return "timed out" }
        return String(format: "%.2f s", seconds)
    }

    private var pointerOverIsland: Bool {
        window.islandFrame.contains(NSEvent.mouseLocation)
    }

    // the latest of mouse, click, scroll or key input from a person
    private func secondsSinceUserInput() -> Double {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown, .leftMouseDragged]
        return types.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? 0
    }

    // appkit points are bottom-left based, cg's are top-left of the main display
    private func warp(to point: NSPoint) {
        let height = NSScreen.screens.first?.frame.maxY ?? 0
        CGWarpMouseCursorPosition(CGPoint(x: point.x, y: height - point.y))
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

    private func snapshot(_ label: String, of target: NSWindow? = nil) async {
        // let swiftui finish its transition first
        try? await Task.sleep(for: .milliseconds(600))
        let source = target ?? window
        guard let view = source.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        // the window's own background isn't in the view: paint one so light and dark text both show
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        // in the window's own appearance, or dark-mode text lands on a light background
        source.effectiveAppearance.performAsCurrentDrawingAppearance {
            (target == nil ? NSColor(white: 0.45, alpha: 1) : NSColor.windowBackgroundColor).setFill()
            NSRect(origin: .zero, size: view.bounds.size).fill()
        }
        // source-over: plain draw(in:) copies, transparent pixels and all
        rep.draw(in: NSRect(origin: .zero, size: view.bounds.size), from: .zero, operation: .sourceOver,
                 fraction: 1, respectFlipped: true, hints: nil)
        image.unlockFocus()
        let url = outDir.appendingPathComponent("\(scenario)-\(label).png")
        if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) {
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
        print("  snap \(url.path)")
    }

    // posts a mouse down/up at a control's center, through the normal event path
    @discardableResult
    private func click(_ control: String, in window: NSWindow) -> Bool {
        guard let frame = DebugFrames.frames[control], let content = window.contentView else {
            print("  no frame for \(control)")
            return false
        }
        // swiftui global space is top-left based, window space bottom-left
        let point = NSPoint(x: frame.midX, y: content.bounds.height - frame.midY)
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
