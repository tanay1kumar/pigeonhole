#if DEBUG
import AppKit
import SwiftUI

// the island's shell on the real window, shapes per surface, tiles, displays, reduce motion
//   shapes          snapshots of every surface, the drawn height checked against its target
//   tiles           real clicks on the three tiles and the panel's back button
//   display-change  the window finds its screen again after a display change or a wake
//   motion-reduced  with reduce motion, opens and swaps only fade and the shape runs the short spring
//   idle            rests --idle-seconds (120 by default) for an outside tool to measure, --idle-panel activity|storage keeps a panel open
extension ScenarioRunner {
    // MARK: shapes

    func shapes() async {
        pointerInside()
        guard let folders = folders() else { return }
        _ = folders
        model.collapse()
        _ = await waitFor(2) { self.model.currentState == .collapsed }
        try? await Task.sleep(for: .milliseconds(700))
        await checkShape("collapsed", expected: model.collapsedMetrics.height)

        model.expand()
        await checkShape("home", expected: DesignConstants.homeHeight)

        showTestCard(rows: 1)
        await checkShape("card-single", expected: DesignConstants.singleCardHeight)

        showTestCard(rows: 3)
        await checkShape("card-multi", expected: DesignConstants.expandedHeight)

        model.cardState = .sent(batchId: UUID())
        model.sentSummary = "Sent to \(folders.flowers.name)"
        await checkShape("sent", expected: DesignConstants.statusHeight)

        if let index = model.suggestions.indices.first {
            model.suggestions[index].status = .failed("You're offline")
        }
        model.cardState = .error("You're offline", retry: .resend)
        await checkShape("error", expected: DesignConstants.singleCardHeight)

        model.clearCard()
        model.timing.resultLinger = 600
        model.showUploadResult(IslandStatus(kind: .success, message: "Uploaded to My Drive"))
        await checkShape("status", expected: DesignConstants.statusHeight)
        model.debugResetStatus()

        if let monitor = DebugHooks.dragMonitor {
            monitor.isDraggingAnything = true
            monitor.isDraggingFiles = true
            await checkShape("drop-zone", expected: DesignConstants.homeHeight)
            monitor.isDraggingFiles = false
            monitor.isDraggingAnything = false
            _ = await waitFor(2) { !self.model.showsDropZone }
            // a stand-in move inside, like a real one it cancels hover's drag-end collapse
            pointerInside()
        }

        model.show(.activity)
        await checkShape("activity", expected: DesignConstants.expandedHeight)
        model.show(.storage)
        await checkShape("storage", expected: DesignConstants.expandedHeight)

        // hit-testing follows the shape, 200 pt down is inside a panel but below home
        let below = NSPoint(x: window.islandFrame.midX, y: window.frame.maxY - DesignConstants.topOverhang - 200)
        DebugPointer.override = below
        try? await Task.sleep(for: .milliseconds(800))
        check(model.currentState == .expanded, "200 pt down stays open over the storage panel")
        check(!window.ignoresMouseEvents, "and takes clicks there")
        model.show(.home)
        DebugPointer.override = below
        check(window.ignoresMouseEvents, "below the shorter home the clicks go to the app underneath")
        let closed = await waitFor(1) { self.model.currentState == .collapsed }
        check(closed != nil, "200 pt down is below home, it closes (\(format(closed)))")

        // a status holds it open, the band under it still lets clicks through
        pointerInside()
        model.timing.resultLinger = 600
        model.showUploadResult(IslandStatus(kind: .success, message: "Uploaded to My Drive"))
        _ = await waitFor(2) { self.model.currentState == .expanded }
        DebugPointer.override = below
        try? await Task.sleep(for: .milliseconds(200))
        check(model.currentState == .expanded && window.ignoresMouseEvents, "under a pinned status the band below is click-through")
        pointerInside()
        check(!window.ignoresMouseEvents, "over the status it takes clicks")
        model.debugResetStatus()

        // the screen's top row is inside the notch, the pointer pinned to the top edge
        model.collapse()
        _ = await waitFor(2) { self.model.currentState == .collapsed }
        try? await Task.sleep(for: .milliseconds(400))
        DebugPointer.override = NSPoint(x: window.pillFrame.midX, y: window.pillFrame.maxY)
        let opened = await waitFor(1) { self.model.currentState == .expanded }
        try? await Task.sleep(for: .milliseconds(600))
        check(opened != nil && model.currentState == .expanded, "the pointer pinned to the top edge opens it and keeps it open")
    }

    // snapshot after it settles, then the black shape's height down the middle
    private func checkShape(_ label: String, expected: CGFloat) async {
        await snapshot(label)
        guard let height = drawnShapeHeight() else {
            check(expected == 0, "\(label): nothing drawn (expected \(Int(expected)) pt)")
            return
        }
        check(abs(height - expected) <= 4, String(format: "%@: shape is %.0f pt tall, target %.0f", label, height, expected))
    }

    // the lowest black pixel near the middle column, measured from the island's top edge
    func drawnShapeHeight() -> CGFloat? {
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsHigh) / view.bounds.height
        let top = Int(DesignConstants.topOverhang * scale)
        var bottom: Int?
        let middle = rep.pixelsWide / 2
        for y in top..<rep.pixelsHigh {
            for x in [middle - Int(100 * scale), middle, middle + Int(100 * scale)] {
                guard let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.95 else { continue }
                if max(color.redComponent, color.greenComponent, color.blueComponent) < 0.03 {
                    bottom = y
                }
            }
        }
        guard let bottom else { return nil }
        return CGFloat(bottom + 1 - top) / scale
    }

    // MARK: tiles

    func tiles() async {
        pointerInside()
        model.expand()
        _ = await waitFor(2) { self.model.currentState == .expanded && DebugFrames.frames["tile-activity"] != nil }
        await snapshot("1-home")
        check(await tap("tile-activity"), "clicked the Activity tile")
        let activity = await waitFor(2) { self.model.content == .activity }
        check(activity != nil, "Activity opens its panel (\(format(activity)))")
        await snapshot("2-activity")
        check(await tap("back"), "clicked back")
        let home = await waitFor(2) { self.model.content == .home }
        check(home != nil, "back goes home (\(format(home)))")
        check(await tap("tile-storage"), "clicked the Storage tile")
        let storage = await waitFor(2) { self.model.content == .storage }
        check(storage != nil, "Storage opens its panel")
        await snapshot("3-storage")
        // closing and opening again starts at home
        model.collapse()
        _ = await waitFor(2) { self.model.currentState == .collapsed }
        model.expand()
        check(model.content == .home, "the next open starts at home")
        check(await tap("tile-settings"), "clicked the Settings tile")
        let opened = await waitFor(2) { self.app.settingsWindow?.isVisible == true }
        check(opened != nil, "Settings opens the Settings window (\(format(opened)))")
        let closed = await waitFor(2) { self.model.currentState == .collapsed }
        check(closed != nil, "and the island gets out of the way (\(format(closed)))")
        app.settingsWindow?.close()
    }

    // MARK: rest

    // nothing happens for a while, so an outside tool can measure what the island costs at rest
    // --idle-panel activity keeps that panel open instead, nothing in it may tick
    func idleRest() async {
        let arguments = CommandLine.arguments
        let seconds = arguments.firstIndex(of: "--idle-seconds").flatMap { $0 + 1 < arguments.count ? Double(arguments[$0 + 1]) : nil } ?? 120
        let panelName = arguments.firstIndex(of: "--idle-panel").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        let panel: IslandSurface? = panelName == "activity" ? .activity : panelName == "storage" ? .storage : nil
        // a misspelled panel would rest closed and still pass
        if let panelName, panel == nil {
            check(false, "--idle-panel \(panelName) isn't activity or storage")
            return
        }
        if let panel {
            // rows with relative times, so anything ticking would show up
            if panel == .activity, let store = app.activityStore, store.entries.isEmpty {
                store.record((1...3).map { minutes in
                    ActivityEntry(kind: .sent, date: Date().addingTimeInterval(Double(-minutes * 120)), name: "resting-\(minutes).pdf",
                                  bytes: 1000, driveFileId: "idle\(minutes)", destinationName: "flowers")
                })
            }
            pointerInside()
            model.show(panel)
        } else {
            pointerOutside()
        }
        print("idle: pid \(getpid()), resting \(Int(seconds)) s, \(panelName ?? "closed")")
        restsAsUsual("at the start")
        try? await Task.sleep(for: .seconds(seconds))
        if let panel {
            check(model.isExpanded && model.surface == panel, "it stayed open on the \(panelName ?? "") panel the whole time")
        } else {
            check(!model.isExpanded, "it stayed closed the whole time")
        }
        restsAsUsual("at the end")
    }

    // a locked screen covers the island and macos naps the app harder, its numbers would read low
    // an app in front runs the 10 Hz poll, that isn't rest either
    private func restsAsUsual(_ when: String) {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let locked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
        let visible = window.occlusionState.contains(.visible)
        print("  \(when): locked \(locked), island visible \(visible), app active \(NSApp.isActive)")
        check(!locked && visible && !NSApp.isActive, "screen unlocked, island on screen, app in the background \(when)")
    }

    // MARK: displays

    func displayChange() async {
        let home = window.frame
        print("  island window at \(Int(home.minX)),\(Int(home.minY)) \(Int(home.width))x\(Int(home.height))")
        window.setFrameOrigin(NSPoint(x: home.minX - 300, y: home.minY - 300))
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        let back = await waitFor(1) { self.window.frame == home }
        check(back != nil, "a display change puts it back on the notch (\(Int(window.frame.minX)),\(Int(window.frame.minY)))")
        window.setFrameOrigin(NSPoint(x: home.minX + 200, y: home.minY - 100))
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: NSWorkspace.shared)
        let woke = await waitFor(1) { self.window.frame == home }
        check(woke != nil, "so does waking up (\(Int(window.frame.minX)),\(Int(window.frame.minY)))")
        if let screen = window.islandScreen {
            let notch = window.pillFrame
            print("  notch \(Int(notch.width))x\(Int(notch.height)) at x \(Int(notch.minX)), \(screen.hasNotch ? "a real notch" : "no notch, hover zone")")
            check(abs(notch.midX - screen.notchCenterX) < 1, "the hover zone is centered on the notch")
        }
    }

    // MARK: reduce motion

    // with reduce motion opens and swaps only fade, and the shape runs the short spring without bounce
    // each transition builder notes what it returned, a snapshot can't tell a 0.97 scale apart
    func motionReduced() async {
        pointerInside()
        DebugMotion.transitions = [:]
        let normal = await openSamples()
        await panelAndBack()
        let normalKinds = DebugMotion.transitions
        model.debugReduceMotion = true
        try? await Task.sleep(for: .milliseconds(300))
        // only what the reduced open and swap build counts
        DebugMotion.transitions = [:]
        let reduced = await openSamples()
        await panelAndBack()
        let reducedKinds = DebugMotion.transitions
        model.debugReduceMotion = false
        print("  shape heights while opening, normal: \(normal.heights.map { Int($0) }), reduced: \(reduced.heights.map { Int($0) })")
        print(String(format: "  open logically done, normal %.0f ms, reduced %.0f ms", normal.logical ?? -1, reduced.logical ?? -1))
        check(normalKinds["open"] == "opacity and scale" && normalKinds["swap"] == "opacity and scale",
              "normal opens and swaps fade and scale the content (\(normalKinds))")
        check(reducedKinds["open"] == "opacity" && reducedKinds["swap"] == "opacity",
              "with reduce motion opens and swaps only fade (\(reducedKinds))")
        // the bounce 0.15 open overshoots by under 1 pt, a snapshot can't see it, the logical time can
        check((normal.logical ?? 0) > 330 && (reduced.logical ?? 1000) < 330,
              "with reduce motion the open is the short spring without bounce")
        await snapshot("reduced-open")
    }

    // a panel and back while open, so the content view's own transition runs
    private func panelAndBack() async {
        model.show(.activity)
        _ = await waitFor(2) { self.model.content == .activity }
        try? await Task.sleep(for: .milliseconds(300))
        model.show(.home)
        _ = await waitFor(2) { self.model.content == .home }
    }

    private struct OpenSamples {
        var heights: [CGFloat] = []
        var logical: Double?
    }

    // the drawn height at a few points of an open, and when the open was logically done
    private func openSamples() async -> OpenSamples {
        var samples = OpenSamples()
        model.collapse()
        _ = await waitFor(2) { self.model.currentState == .collapsed }
        try? await Task.sleep(for: .milliseconds(800))
        let start = CACurrentMediaTime()
        model.expand()
        let number = DebugMotion.lastTracked["expand"]
        _ = await waitFor(2) { DebugMotion.settled("expand.logical", generation: number, since: start) != nil }
        samples.logical = DebugMotion.settled("expand.logical", generation: number, since: start)
        for delay in [80, 140, 200, 260, 320] {
            model.collapse()
            _ = await waitFor(2) { self.model.currentState == .collapsed }
            try? await Task.sleep(for: .milliseconds(800))
            let opened = CACurrentMediaTime()
            model.expand()
            while CACurrentMediaTime() < opened + Double(delay) / 1000 {
                try? await Task.sleep(for: .milliseconds(2))
            }
            if let height = drawnShapeHeight() {
                samples.heights.append(height)
            }
        }
        return samples
    }
}
#endif
