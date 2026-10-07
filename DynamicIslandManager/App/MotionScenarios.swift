#if DEBUG
import AppKit
import SwiftUI

// how the island moves, measured on the real window (no cursor needed)
//   motion, motion-card, motion-status   20 open/close cycles each
//   motion-hover    stand-in pointer onto the notch, until the open is committed, the next frame after,
//                   and the earliest vsync a wider island can show at
//   motion-mid      snapshots part way through an open
//   bodies          body evaluations for stand-in pointer moves (no real onHover), a finder drag, a status change
// numbers are printed, --check-motion also checks them against the targets
// time with --no-debug-frames, the scenario button finder costs time every frame
// the probe only sees frames main missed, not ones the render server showed late
extension ScenarioRunner {
    struct MotionRun {
        var open: [FrameProbe.Stats] = []
        var close: [FrameProbe.Stats] = []
        var openSettle: [Double] = []       // ms until the animation was removed
        var openLogical: [Double] = []      // ms until it was logically done
        var closeSettle: [Double] = []
        var closeLogical: [Double] = []
        var expandCommit: [Double] = []     // main-thread ms, expand() to the shape's commit
        var mountCommit: [Double] = []      // main-thread ms, the content's own commit a refresh later
        var openMain: [Double] = []         // both, what an open costs the main thread
        var collapseCommit: [Double] = []
        var dropped = 0                     // cycles real input touched, or where the island moved on its own
    }

    var checksMotion: Bool {
        CommandLine.arguments.contains("--check-motion")
    }

    var motionCycles: Int {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--motion-cycles"), index + 1 < arguments.count,
              let cycles = Int(arguments[index + 1]), cycles > 0 else { return 20 }
        return cycles
    }

    // real mouse moves, drags or keys during a cycle, its numbers don't count
    private struct InputMark {
        let events: Int
        let at: Double

        @MainActor
        init() {
            events = DebugHooks.globalMouseEvents
            at = CACurrentMediaTime()
        }
    }

    private func touchedSince(_ mark: InputMark) -> Bool {
        DebugHooks.globalMouseEvents != mark.events
            || DebugHooks.dragMonitor?.isDraggingAnything == true
            || secondsSinceUserInput() < CACurrentMediaTime() - mark.at
    }

    // MARK: open and close cycles

    func motion(_ variant: String) async {
        guard let view = window.contentView else {
            check(false, "island content view")
            return
        }
        // pointer inside the open island but off the notch, hover neither opens nor closes it
        pointerInside()
        var foldAway: () -> Void = {}
        switch variant {
        case "card":
            guard showTestCard(rows: 1) else { return }
            foldAway = { self.model.parked = true }
        case "status":
            model.timing.resultLinger = 600
            model.showUploadResult(IslandStatus(kind: .success, message: "Uploaded to My Drive"))
            foldAway = { self.model.parked = true }
        default:
            break
        }
        foldAway()
        model.collapse()
        _ = await waitFor(2) { self.model.currentState == .collapsed }
        try? await Task.sleep(for: .milliseconds(800))

        let probe = FrameProbe()
        var run = MotionRun()
        for _ in 0..<motionCycles {
            let kept = run
            let mark = InputMark()

            // open
            DebugMotion.lastCommit = [:]
            probe.start(on: view)
            try? await Task.sleep(for: .milliseconds(50))
            let opens = model.currentState == .collapsed
            var start = CACurrentMediaTime()
            model.expand()
            var number = DebugMotion.lastTracked["expand"]
            _ = await waitFor(2.5) { DebugMotion.settled("expand.removed", generation: number, since: start) != nil }
            try? await Task.sleep(for: .milliseconds(100))
            run.open.append(probe.stop())
            if let ms = DebugMotion.settled("expand.removed", generation: number, since: start) { run.openSettle.append(ms) }
            if let ms = DebugMotion.settled("expand.logical", generation: number, since: start) { run.openLogical.append(ms) }
            if let commit = DebugMotion.lastCommit["expand"] { run.expandCommit.append(commit.ms) }
            if let mount = DebugMotion.lastCommit["contentMount"] {
                run.mountCommit.append(mount.ms)
                if let shape = DebugMotion.lastCommit["expand"] { run.openMain.append(shape.ms + mount.ms) }
            }

            // close
            foldAway()
            DebugMotion.lastCommit = [:]
            probe.start(on: view)
            try? await Task.sleep(for: .milliseconds(50))
            let closes = model.currentState == .expanded
            start = CACurrentMediaTime()
            model.collapse()
            number = DebugMotion.lastTracked["collapse"]
            _ = await waitFor(2.5) { DebugMotion.settled("collapse.removed", generation: number, since: start) != nil }
            try? await Task.sleep(for: .milliseconds(100))
            run.close.append(probe.stop())
            if let ms = DebugMotion.settled("collapse.removed", generation: number, since: start) { run.closeSettle.append(ms) }
            if let ms = DebugMotion.settled("collapse.logical", generation: number, since: start) { run.closeLogical.append(ms) }
            if let commit = DebugMotion.lastCommit["collapse"] { run.collapseCommit.append(commit.ms) }
            check(model.currentState == .collapsed, "cycle closed")

            // something else moved the island or someone used the mac, drop the cycle
            if !opens || !closes || touchedSince(mark) {
                run = kept
                run.dropped += 1
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        report(run, variant: variant)
        if variant == "card" || variant == "status" {
            model.parked = false
        }
    }

    // a confident card with real files, no classifying
    @discardableResult
    func showTestCard(rows: Int) -> Bool {
        let destinations = app.destinationStore.destinations
        guard !destinations.isEmpty else {
            check(false, "needs at least one destination for a card")
            return false
        }
        let files = [sunflower, resumePDF(), receiptPNG()].prefix(rows)
        model.suggestions = files.map { url in
            var row = FileSuggestion(file: FileItem(url: url))
            row.ranked = destinations.enumerated().map { index, destination in
                RankedDestination(destination: destination, raw: index == 0 ? 0.3 : 0.05, p: index == 0 ? 0.8 : 0.1)
            }
            row.level = .confident
            row.chosen = destinations.first
            row.why = "looks like: flower, sunflower"
            row.status = .ready
            return row
        }
        model.cardState = .suggesting
        return true
    }

    private func report(_ run: MotionRun, variant: String) {
        let refresh = run.open.first?.refresh ?? 1000.0 / 60
        let halves = run.open + run.close
        let cycleGaps = zip(run.open, run.close).map { max($0.maxGap, $1.maxGap) }
        let doubles = halves.reduce(0) { $0 + $1.doubleGaps }
        let doubleHalves = halves.filter { $0.doubleGaps > 0 }.count
        let longs = halves.reduce(0) { $0 + $1.longGaps }
        let missed = halves.reduce(0) { $0 + $1.missed }
        print(String(format: "  motion %@: %d cycles counted at %.1f ms a frame (%.0f Hz), %d dropped (real input, or the island moved on its own)",
                     variant, run.open.count, refresh, 1000 / refresh, run.dropped))
        print("  per-cycle max gap: \(stat(cycleGaps, unit: "ms", refresh: refresh))")
        print("  open max gap: \(stat(run.open.map(\.maxGap), unit: "ms", refresh: refresh)), frames \(stat(run.open.map { Double($0.frames) }, unit: ""))")
        print("  close max gap: \(stat(run.close.map(\.maxGap), unit: "ms", refresh: refresh)), frames \(stat(run.close.map { Double($0.frames) }, unit: ""))")
        print("  main-thread gaps > 1.5x: \(longs), > 2x: \(doubles) in \(doubleHalves) halves, refreshes missed: \(missed) (all \(halves.count) halves)")
        print("  open settles: logical \(stat(run.openLogical, unit: "ms")), removed \(stat(run.openSettle, unit: "ms"))")
        print("  close settles: logical \(stat(run.closeLogical, unit: "ms")), removed \(stat(run.closeSettle, unit: "ms"))")
        // near 1x means the close ran the open's animation
        if !run.openSettle.isEmpty && !run.closeSettle.isEmpty {
            print(String(format: "  close vs open, removed: %.2fx", percentile(run.closeSettle, 0.5) / percentile(run.openSettle, 0.5)))
        }
        print("  main thread, expand() to committed: \(stat(run.expandCommit, unit: "ms")); collapse(): \(stat(run.collapseCommit, unit: "ms"))")
        print("  main thread, the content's commit: \(stat(run.mountCommit, unit: "ms")); per open, both: \(stat(run.openMain, unit: "ms"))")
        print("  late callbacks within a frame, worst: \(stat(halves.map(\.maxLate), unit: "ms"))")
        for (index, stats) in run.open.enumerated() where stats.missed > 0 {
            print("    open \(index + 1): \(stats.line)")
        }
        for (index, stats) in run.close.enumerated() where stats.missed > 0 {
            print("    close \(index + 1): \(stats.line)")
        }
        if checksMotion {
            let starved = halves.filter(\.starved).count
            check(!halves.isEmpty && starved == 0, "every half saw at least half its frames (\(starved) of \(halves.count) didn't)")
            check(run.dropped * 5 <= motionCycles, "at most a fifth of the cycles dropped for real input (\(run.dropped))")
            check(run.openSettle.count == run.open.count && run.closeSettle.count == run.close.count, "every open and close settled")
            check(doubles == 0, "no main-thread frame gap over 2x the refresh interval (\(doubles))")
            check(percentile(cycleGaps, 0.95) <= refresh * 1.5,
                  String(format: "p95 per-cycle max gap %.1f ms within 1.5x (%.1f ms)", percentile(cycleGaps, 0.95), refresh * 1.5))
            // a missing content commit leaves openMain short, and that fails too
            check(run.openMain.count == run.open.count && percentile(run.openMain, 0.95) < 8,
                  String(format: "main thread per open p95 %.1f ms under 8 ms, shape and content (%d of %d opens)",
                         percentile(run.openMain, 0.95), run.openMain.count, run.open.count))
        }
    }

    func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        let rank = p * Double(sorted.count - 1)
        let low = Int(rank.rounded(.down)), high = Int(rank.rounded(.up))
        return sorted[low] + (sorted[high] - sorted[low]) * (rank - Double(low))
    }

    func stat(_ values: [Double], unit: String, refresh: Double? = nil) -> String {
        guard !values.isEmpty else { return "n/a" }
        func one(_ value: Double) -> String {
            var text = String(format: "%.1f%@", value, unit.isEmpty ? "" : " " + unit)
            if let refresh {
                text += String(format: " (%.2fx)", value / refresh)
            }
            return text
        }
        return "p50 \(one(percentile(values, 0.5))), p95 \(one(percentile(values, 0.95))), max \(one(values.max()!)) [n=\(values.count)]"
    }

    // MARK: pointer onto the notch

    // the stand-in pointer runs hover's handler like a real mouse event does, minus event delivery
    func motionHover() async {
        guard let view = window.contentView else { return }
        let pill = window.pillFrame
        let screen = NSScreen.screens.first?.frame ?? .zero
        let away = NSPoint(x: screen.minX + 200, y: screen.midY)
        let probe = FrameProbe()
        var toCommit: [Double] = []
        var toFrame: [Double] = []
        var toGrown: [Double] = []
        var dropped = 0
        var refresh = 1000.0 / 60
        for _ in 0..<motionCycles {
            DebugPointer.override = away
            _ = await waitFor(2) { self.model.currentState == .collapsed }
            try? await Task.sleep(for: .milliseconds(600))
            let mark = InputMark()
            DebugMotion.lastCommit = [:]
            GrowthStamp.shared.arm(baseline: model.collapsedMetrics.width)
            probe.start(on: view)
            try? await Task.sleep(for: .milliseconds(50))
            let moved = CACurrentMediaTime()
            DebugPointer.override = NSPoint(x: pill.midX, y: pill.midY)
            _ = await waitFor(1) { DebugMotion.lastCommit["expand"] != nil && GrowthStamp.shared.grewAt != nil }
            try? await Task.sleep(for: .milliseconds(100))
            let stats = probe.stop()
            let grew = GrowthStamp.shared.grewAt
            GrowthStamp.shared.disarm()
            refresh = stats.refresh
            guard let commit = DebugMotion.lastCommit["expand"] else {
                check(false, "hovering the notch expanded it")
                continue
            }
            if touchedSince(mark) {
                dropped += 1
                continue
            }
            toCommit.append((commit.at - moved) * 1000)
            if let frame = stats.firstFrame(after: commit.at) {
                toFrame.append((frame - moved) * 1000)
            }
            // the earliest vsync the wider frame can show at, the probe never sees it presented
            if let grew, let shown = stats.firstFrame(after: grew) {
                toGrown.append((shown - moved) * 1000)
            }
        }
        DebugPointer.override = away
        print("  stand-in pointer onto the notch, \(dropped) of \(motionCycles) dropped for real input")
        print("  until the open is committed: \(stat(toCommit, unit: "ms", refresh: refresh))")
        print("  until the next frame after that: \(stat(toFrame, unit: "ms", refresh: refresh))")
        print("  until the earliest vsync a wider frame can show at (a lower bound): \(stat(toGrown, unit: "ms", refresh: refresh))")
        if checksMotion {
            // to the commit, the wait for the next vsync adds up to a frame on top
            check(percentile(toCommit, 0.95) <= refresh,
                  String(format: "pointer to committed open p95 %.1f ms within one frame", percentile(toCommit, 0.95)))
        }
    }

    // MARK: part way through an open

    func motionMid() async {
        pointerInside()
        model.collapse()
        _ = await waitFor(2) { self.model.currentState == .collapsed }
        try? await Task.sleep(for: .milliseconds(800))
        snapshotNow("0-collapsed")
        // how long an open takes, then snapshots at fractions of it
        let start = CACurrentMediaTime()
        model.expand()
        let number = DebugMotion.lastTracked["expand"]
        _ = await waitFor(2.5) { DebugMotion.settled("expand.logical", generation: number, since: start) != nil }
        let logical = (DebugMotion.settled("expand.logical", generation: number, since: start) ?? 500) / 1000
        print(String(format: "  open is logically done after %.0f ms", logical * 1000))
        for fraction in [0.25, 0.5, 0.75] {
            model.collapse()
            _ = await waitFor(2) { self.model.currentState == .collapsed }
            try? await Task.sleep(for: .milliseconds(900))
            let opened = CACurrentMediaTime()
            model.expand()
            let target = opened + logical * fraction
            while CACurrentMediaTime() < target {
                try? await Task.sleep(for: .milliseconds(2))
            }
            let height = drawnShapeHeight()
            snapshotNow(String(format: "%d-open-%02.0f", Int(fraction * 4), fraction * 100),
                        note: String(format: "%.0f ms in, %@", (CACurrentMediaTime() - opened) * 1000,
                                     height.map { String(format: "shape %.0f pt tall", $0) } ?? "no opaque shape"))
            // one solid shape the whole way, the old cross-fade had no opaque pixel at 25%
            check(height.map { $0 > model.collapsedMetrics.height } ?? false,
                  String(format: "at %.0f%% the island is one opaque shape, taller than the notch", fraction * 100))
            try? await Task.sleep(for: .milliseconds(800))
        }
        snapshotNow("4-open-done")
    }

    // right now, no waiting for transitions
    func snapshotNow(_ label: String, note: String = "") {
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        NSColor(white: 0.45, alpha: 1).setFill()
        NSRect(origin: .zero, size: view.bounds.size).fill()
        rep.draw(in: NSRect(origin: .zero, size: view.bounds.size), from: .zero, operation: .sourceOver,
                 fraction: 1, respectFlipped: true, hints: nil)
        image.unlockFocus()
        let url = outDir.appendingPathComponent("\(scenario)-\(label).png")
        if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) {
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
        print("  snap \(url.path)\(note.isEmpty ? "" : " (\(note))")")
    }

    // MARK: body evaluations

    func bodies() async {
        guard let monitor = DebugHooks.dragMonitor else {
            check(false, "drag monitor hook")
            return
        }
        let screen = NSScreen.screens.first?.frame ?? .zero
        let center = NSPoint(x: screen.midX, y: screen.midY - 150)
        pointerOutside()
        model.collapse()
        _ = await waitFor(2) { self.model.currentState == .collapsed }
        try? await Task.sleep(for: .seconds(1))

        // 1. mouse moving over another app, 3 s of stand-in moves at 120 a second through hover's handler
        BodyCounts.reset()
        for step in 0..<360 {
            let angle = Double(step) / 30 * .pi
            DebugPointer.override = NSPoint(x: center.x + 300 * cos(angle), y: center.y + 200 * sin(angle))
            try? await Task.sleep(for: .milliseconds(8))
        }
        let moving = BodyCounts.counts
        print("  360 stand-in pointer moves away from the island, collapsed: \(BodyCounts.summary)")
        if checksMotion {
            check(moving["IslandView", default: 0] == 0, "no island body evaluations while the mouse moves elsewhere")
        }

        // same with the island open, the stand-in can't fire the views' onHover
        pointerInside()
        model.expand()
        try? await Task.sleep(for: .seconds(1))
        BodyCounts.reset()
        let inside = window.islandFrame
        for step in 0..<240 {
            let angle = Double(step) / 20 * .pi
            DebugPointer.override = NSPoint(x: inside.midX + 120 * cos(angle), y: inside.minY + 60 + 30 * sin(angle))
            try? await Task.sleep(for: .milliseconds(8))
        }
        print("  240 stand-in pointer moves inside the open island, no real hover: \(BodyCounts.summary)")

        // a drag that isn't files, with the tiles showing, nothing should redraw
        // the pointer stays near the notch, further away the drag would close the island
        DebugPointer.override = NSPoint(x: window.pillFrame.midX, y: window.pillFrame.minY - 20)
        model.expand()
        try? await Task.sleep(for: .seconds(1))
        BodyCounts.reset()
        let nearNotch = DebugPointer.override
        monitor.isDraggingAnything = true
        try? await Task.sleep(for: .seconds(1))
        monitor.isDraggingAnything = false
        // the drag's end schedules hover's collapse, only a pointer move inside cancels it
        // with this app in back and nobody at the mac none comes, so move the stand-in once
        try? await Task.sleep(for: .milliseconds(50))
        DebugPointer.override = nearNotch
        try? await Task.sleep(for: .milliseconds(450))
        let otherDrag = BodyCounts.counts
        print("  a window or text drag elsewhere, tiles showing: \(BodyCounts.summary)")
        check(otherDrag["IslandView", default: 0] == 0 && otherDrag["TileView", default: 0] == 0,
              "drags that aren't files don't re-render the island or its tiles")

        // 2. a finder drag, expands to the drop zone then goes back
        pointerOutside()
        model.collapse()
        _ = await waitFor(2) { self.model.currentState == .collapsed }
        try? await Task.sleep(for: .seconds(1))
        BodyCounts.reset()
        monitor.isDraggingAnything = true
        monitor.isDraggingFiles = true
        try? await Task.sleep(for: .seconds(1))
        let duringDrag = BodyCounts.summary
        monitor.isDraggingFiles = false
        monitor.isDraggingAnything = false
        // ended away from the island, it closes from the drop zone, home never shows in between
        var sawHome = false
        let closed = await waitFor(3) {
            if self.model.currentState == .expanded && self.model.content == .home {
                sawHome = true
            }
            return self.model.currentState == .collapsed
        }
        check(closed != nil && !sawHome, "a finder drag that ends away closes from the drop zone, no home in between (\(format(closed)))")
        pointerOutside()
        try? await Task.sleep(for: .seconds(1))
        print("  a finder drag that ends elsewhere: \(BodyCounts.summary) (first 1 s: \(duringDrag))")

        // cancelled with the pointer still on the notch, same, no home before it closes
        monitor.isDraggingAnything = true
        monitor.isDraggingFiles = true
        _ = await waitFor(2) { self.model.content == .dropZone && self.model.currentState == .expanded }
        let notch = NSPoint(x: window.pillFrame.midX, y: window.pillFrame.midY)
        DebugPointer.override = notch
        try? await Task.sleep(for: .milliseconds(500))
        BodyCounts.reset()
        monitor.isDraggingFiles = false
        monitor.isDraggingAnything = false
        var sawHomeOver = false
        let closedOver = await waitFor(3) {
            if self.model.currentState == .expanded && self.model.content == .home {
                sawHomeOver = true
            }
            return self.model.currentState == .collapsed
        }
        check(closedOver != nil && !sawHomeOver, "a finder drag cancelled over the island closes from the drop zone too (\(format(closedOver)))")
        // the drop zone stays through the fade, home isn't even laid out as it goes
        try? await Task.sleep(for: .milliseconds(500))
        check(BodyCounts.counts["TileView", default: 0] == 0, "and the tiles never render on the way out (\(BodyCounts.summary))")
        // the pointer still on the notch doesn't open it again, leaving and coming back does
        DebugPointer.override = NSPoint(x: notch.x + 4, y: notch.y)
        try? await Task.sleep(for: .milliseconds(400))
        check(model.currentState == .collapsed, "the pointer left on the notch after a cancelled drag doesn't reopen it")
        pointerOutside()
        DebugPointer.override = notch
        let reopened = await waitFor(2) { self.model.currentState == .expanded }
        check(reopened != nil, "hovering the notch again opens it (\(format(reopened)))")
        pointerOutside()
        _ = await waitFor(2) { self.model.currentState == .collapsed }

        // 3. a status change, shows then clears
        BodyCounts.reset()
        model.timing.resultLinger = 1
        model.showUploadResult(IslandStatus(kind: .success, message: "Uploaded to My Drive"))
        _ = await waitFor(3) { self.model.status == nil }
        _ = await waitFor(2) { self.model.currentState == .collapsed }
        try? await Task.sleep(for: .seconds(1))
        print("  a status shown for 1 s, then cleared: \(BodyCounts.summary)")

        // 4. something changes while collapsed, nothing on screen should redraw
        BodyCounts.reset()
        model.cardNote = "changed while collapsed"
        try? await Task.sleep(for: .milliseconds(300))
        model.cardNote = nil
        model.authExpired = true
        try? await Task.sleep(for: .milliseconds(300))
        model.authExpired = false
        try? await Task.sleep(for: .milliseconds(300))
        print("  4 published changes while collapsed: \(BodyCounts.summary)")

        // 5. hover's handler per stand-in move, without real event delivery or wakeup
        let moves = 2000
        let started = CACurrentMediaTime()
        for step in 0..<moves {
            DebugPointer.override = NSPoint(x: center.x + Double(step % 200), y: center.y)
        }
        let perMove = (CACurrentMediaTime() - started) / Double(moves) * 1_000_000
        print(String(format: "  hover's handler per stand-in move: %.1f us on the main thread (%d moves, no event delivery)", perMove, moves))

        // 6. real mouse moves over other apps, if someone is using the mac
        BodyCounts.reset()
        let before = DebugHooks.globalMouseEvents
        try? await Task.sleep(for: .seconds(10))
        let seen = DebugHooks.globalMouseEvents - before
        print("  10 s of real use: \(seen) global mouse event(s), bodies: \(BodyCounts.summary)\(seen == 0 ? " (nobody moved the mouse)" : "")")
    }
}
#endif
