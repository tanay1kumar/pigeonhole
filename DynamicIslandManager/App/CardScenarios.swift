#if DEBUG
import AppKit
import SwiftUI

// step 5 on the real island (the plan §5 step 5 "done when"): real sign-in, your real drive folders,
// files dropped through handleDrop (what the island's .onDrop calls), clicks posted to the card's
// own buttons. every upload is deleted again, by undo or in reset()
extension ScenarioRunner {
    static let resumeText = """
    Priya Shah
    priya.shah@example.com, (555) 010-2233
    Education
    Bachelor of Science in Computer Science, State University, 2025. GPA 3.8.
    Experience
    Software Engineering Intern, Northwind Labs, summer 2024: built a Swift app for field reports \
    and cut crash rates by 40 percent.
    Teaching Assistant, Data Structures, 2023 to 2025: led weekly labs for 60 students.
    Skills
    Swift, Python, SQL, Git, unit testing, user interviews.
    Projects
    Campus bike map, an iOS app used by 900 students. References available on request.
    """

    static let boxB = "resumes CVs cover letters"

    // MARK: the user's folders and test files

    var flowers: Destination? { destination(named: "flowers") }
    var resumes: Destination? { destination(named: "resumes") }
    var receipts: Destination? { destination(named: "reciepts") ?? destination(named: "receipts") }

    func destination(named name: String) -> Destination? {
        app.destinationStore.destinations.first { $0.name.lowercased() == name }
    }

    // the three folders these checks send to; a missing one fails the scenario
    func folders() -> (flowers: Destination, resumes: Destination, receipts: Destination)? {
        guard let flowers, let resumes, let receipts else {
            check(false, "needs destinations flowers, resumes and reciepts (have: \(app.destinationStore.destinations.map(\.name)))")
            return nil
        }
        return (flowers, resumes, receipts)
    }

    var sunflower: URL {
        URL(fileURLWithPath: "/Library/User Pictures/Flowers/Sunflower.heic")
    }

    // a resume with a name that says nothing, like the plan's doc_final2.pdf
    func resumePDF() -> URL {
        let url = outDir.appendingPathComponent("doc_final2.pdf")
        if !FileManager.default.fileExists(atPath: url.path) {
            TestFiles.writeTextPDF(Self.resumeText, to: url)
        }
        return url
    }

    func receiptPNG() -> URL {
        let url = outDir.appendingPathComponent("scan_0912.png")
        if !FileManager.default.fileExists(atPath: url.path) {
            TestFiles.writeImage(TestFiles.renderText(TestFiles.receiptText, width: 700, height: 1000, fontSize: 30), to: url)
        }
        return url
    }

    // MARK: card helpers

    func drop(_ urls: [URL]) {
        model.handleDrop(urls.map { NSItemProvider(object: $0 as NSURL) })
    }

    // drop, then wait until every row has its suggestion
    @discardableResult
    func dropAndWait(_ urls: [URL], timeout: Double = 15) async -> Double? {
        drop(urls)
        let ready = await waitFor(timeout) {
            self.model.cardState == .suggesting && !self.model.suggestions.contains { $0.status == .classifying }
        }
        check(ready != nil, "\(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"): suggestions ready (\(format(ready)))")
        return ready
    }

    var isSent: Bool {
        if case .sent = model.cardState { return true }
        return false
    }

    // what the classifier said, for the log
    func describe(_ row: FileSuggestion) -> String {
        let ranked = row.ranked.map { String(format: "%@ %.3f", $0.destination.name, $0.raw) }.joined(separator: ", ")
        return "\(row.displayName): \(row.level), why \"\(row.why)\" [\(ranked)]"
    }

    func dropToRankText() -> String {
        model.lastDropToRank.map { String(format: "%.0f ms", $0) } ?? "-"
    }

    // the island stays open for clicks without moving the real cursor
    func pointerInside() {
        DebugPointer.override = NSPoint(x: window.islandFrame.midX, y: window.islandFrame.minY + 40)
    }

    func pointerOutside() {
        let screen = NSScreen.screens.first?.frame ?? .zero
        DebugPointer.override = NSPoint(x: screen.minX + 200, y: screen.midY)
    }

    // waits for the control to be laid out and its transition to settle, then clicks it
    func tap(_ control: String, in target: NSWindow? = nil) async -> Bool {
        guard await waitFor(2, { DebugFrames.frames[control] != nil }) != nil else {
            print("  no frame for \(control)")
            return false
        }
        try? await Task.sleep(for: .milliseconds(450))
        return click(control, in: target ?? window)
    }

    // sends, waits for "Sent", and remembers the uploads for cleanup
    func waitForSent(_ what: String) async -> [String] {
        let sent = await waitFor(40) { self.isSent }
        check(sent != nil, "\(what) (\(format(sent)))")
        let ids = model.suggestions.compactMap(\.sentFileId)
        pendingDeletes += ids
        return ids
    }

    // opens a swiftui Menu with a posted click, then picks an item the way clicking it does.
    // the menu runs its own event loop; a timer in the common modes still fires inside it
    func pick(_ title: String, fromMenu control: String) async -> Bool {
        guard await waitFor(2, { DebugFrames.frames[control] != nil }) != nil else {
            print("  no frame for \(control)")
            return false
        }
        try? await Task.sleep(for: .milliseconds(450))
        let box = MenuPick()
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            MainActor.assumeIsolated {
                box.menu = note.object as? NSMenu
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let picker = Timer(timeInterval: 0.1, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard let menu = box.menu else { return }
                timer.invalidate()
                box.titles = menu.items.map(\.title)
                if let index = menu.items.firstIndex(where: { $0.title == title }) {
                    menu.performActionForItem(at: index)
                    box.picked = true
                }
                menu.cancelTracking()
                box.done = true
            }
        }
        RunLoop.main.add(picker, forMode: .common)
        defer { picker.invalidate() }
        guard click(control, in: window) else { return false }
        let done = await waitFor(3) { box.done }
        if done == nil {
            print("  the \(control) menu never opened")
        } else if !box.picked {
            print("  no \"\(title)\" in the \(control) menu: \(box.titles)")
        }
        return box.picked
    }

    // types the way the keyboard does: click into the field, insert the text, then Return (or not)
    // the window shares one field editor: it's this field's only once its delegate is the field
    func type(_ text: String, into control: String, in target: NSWindow, pressReturn: Bool) async -> Bool {
        guard await tap(control, in: target), let field = textField(at: control, in: target) else { return false }
        func editorOfField() -> NSTextView? {
            (target.firstResponder as? NSTextView).flatMap { $0.delegate === field ? $0 : nil }
        }
        var editor = await waitForValue(1, editorOfField)
        if editor == nil {
            // the window wasn't key, so the click didn't focus the field: focus it directly
            print("  the click didn't focus \(control) (window key: \(target.isKeyWindow)), focusing it directly")
            target.makeFirstResponder(field)
            editor = await waitForValue(1, editorOfField)
        }
        guard let editor else { return false }
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
        if pressReturn {
            editor.insertNewline(nil)
        }
        return true
    }

    // the text field under a control's frame (swiftui's TextField is an NSTextField in a host view).
    // compared in window coordinates: the hosting view itself is flipped
    func textField(at control: String, in target: NSWindow) -> NSTextField? {
        guard let frame = DebugFrames.frames[control], let content = target.contentView else { return nil }
        let point = NSPoint(x: frame.midX, y: target.frame.height - frame.midY)
        return textFields(in: content).first { field in
            field.convert(field.bounds, to: nil).insetBy(dx: -2, dy: -2).contains(point)
        }
    }

    func textFields(in view: NSView) -> [NSTextField] {
        view.subviews.compactMap { $0 as? NSTextField } + view.subviews.flatMap { textFields(in: $0) }
    }

    func waitForValue<T>(_ timeout: Double, _ value: () -> T?) async -> T? {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if let found = value() { return found }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return value()
    }

    // opens the setup window and waits until it takes clicks: while the app isn't active yet, a
    // window's first click only activates it and never reaches the button (normal macos behavior)
    func openSetupWindow() async -> NSWindow? {
        NotificationCenter.default.post(name: .showDestinationSetup, object: nil)
        let shown = await waitFor(2) { self.app.destinationsWindow?.isVisible == true }
        check(shown != nil, "the Destinations window opens")
        guard let setup = app.destinationsWindow else { return nil }
        var ready = await waitFor(3) { NSApp.isActive && setup.isKeyWindow }
        if ready == nil {
            NSApp.activate(ignoringOtherApps: true)
            setup.makeKeyAndOrderFront(nil)
            ready = await waitFor(3) { NSApp.isActive && setup.isKeyWindow }
        }
        print("  setup window key and app active: \(ready != nil ? "yes" : "no (active \(NSApp.isActive), key \(setup.isKeyWindow))")")
        try? await Task.sleep(for: .milliseconds(500))
        return setup
    }

    // MARK: drive and learning

    enum DriveLocation: Equatable, CustomStringConvertible {
        case at([String]), gone, unknown(String)

        var description: String {
            switch self {
            case .at(let parents): return "parents \(parents)"
            case .gone: return "gone"
            case .unknown(let why): return "unknown: \(why)"
            }
        }
    }

    func locate(_ id: String) async -> DriveLocation {
        do {
            return .at(try await drive.getFile(id: id).parents ?? [])
        } catch let error as DriveError where error.category == .notFound {
            return .gone
        } catch {
            return .unknown(DriveError.from(error).shortText)
        }
    }

    func examples(_ destination: Destination) -> [Float] {
        app.learningStore?.data(for: destination.id)?.examples.map(\.weight) ?? []
    }

    func negatives(_ destination: Destination) -> [Float] {
        app.learningStore?.data(for: destination.id)?.negatives.map(\.value) ?? []
    }

    // every destination's example and negative counts, to show nothing was learned
    func learnedSummary() -> String {
        (app.learningStore?.snapshot() ?? [:])
            .sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value.examples.count)/\($0.value.negatives.count)" }
            .joined(separator: " ")
    }

    func deletePendingUploads() async {
        let protectedIds = Set(app.destinationStore.destinations.map(\.id))
        for id in pendingDeletes {
            do {
                try await drive.deleteFile(id: id, protectedIds: protectedIds)
                print("  deleted test upload \(id)")
            } catch let error as DriveError where error.category == .notFound {
                print("  test upload \(id) already gone")
            } catch {
                check(false, "delete test upload \(id): \(DriveError.from(error).shortText)")
            }
        }
        pendingDeletes = []
    }

    // MARK: scenarios

    // a folder renamed in drive since it was picked shows its drive name (refreshed after sign-in)
    func namesFollowDrive() async {
        let store = app.destinationStore
        var differences: [String] = []
        for _ in 0..<10 {
            differences = []
            for destination in store.destinations {
                if let file = try? await drive.getFile(id: destination.id, fields: "id,name"), file.name != destination.name {
                    differences.append("\(destination.name) is \(file.name) in drive")
                }
            }
            if differences.isEmpty {
                break
            }
            try? await Task.sleep(for: .seconds(1))
        }
        check(differences.isEmpty, "every destination shows its drive name: \(store.destinations.map(\.name)) \(differences)")
    }

    // Sunflower.heic: Flowers with "looks like: ...flower...", Send puts it there, "Sent to Flowers [Undo]"
    func cardSingle() async {
        guard let folders = folders() else { return }
        pointerInside()
        let learned = examples(folders.flowers).count
        drop([sunflower])
        check(model.cardState == .classifying, "the card says classifying as soon as the drop lands")
        let ready = await waitFor(15) { self.model.cardState == .suggesting }
        check(ready != nil, "suggestion ready (\(format(ready)))")
        print("  dropToRank, first drop: \(dropToRankText())")
        guard let row = model.suggestions.first else {
            check(false, "a row for Sunflower.heic")
            return
        }
        print("  \(describe(row))")
        check(row.top?.id == folders.flowers.id, "top suggestion is \(folders.flowers.name)")
        check(row.why.hasPrefix("looks like:") && row.why.contains("flower"), "why line \"\(row.why)\"")
        await snapshot("1-card")

        check(await tap("send"), "clicked Send")
        let ids = await waitForSent("sent")
        check(model.sentSummary == "Sent to \(folders.flowers.name)", "shows \"\(model.sentSummary ?? "-")\" with Undo")
        await snapshot("2-sent")
        if let id = ids.first {
            let location = await locate(id)
            check(location == .at([folders.flowers.id]), "drive has it in \(folders.flowers.name) (\(location))")
        }
        check(examples(folders.flowers).count == learned + 1 && examples(folders.flowers).last == 1,
              "learned: accepted, w=1 (\(examples(folders.flowers)))")
        let sentAt = Date()
        let gone = await waitFor(8) { self.model.cardState == .idle }
        check(gone != nil, "the undo window ends and the card goes (\(format(Date().timeIntervalSince(sentAt))) after Sent)")

        // the same file again comes from the cache
        await dropAndWait([sunflower])
        print("  dropToRank, warm drop of the same file: \(dropToRankText())")
        check(await tap("dismiss"), "✕")
        _ = await waitFor(2) { self.model.cardState == .idle }
    }

    // Undo within 5 s deletes the copy and reopens the chooser; choosing Receipts is a correction (w=2),
    // with no second negative for Flowers
    func cardUndoCorrect() async {
        guard let folders = folders() else { return }
        pointerInside()
        await dropAndWait([sunflower])
        let flowerExamples = examples(folders.flowers).count
        let flowerNegatives = negatives(folders.flowers).count
        check(await tap("send"), "clicked Send")
        let ids = await waitForSent("sent to \(folders.flowers.name)")
        check(await tap("undo"), "clicked Undo")
        let reopened = await waitFor(15) { self.model.cardState == .suggesting }
        check(reopened != nil, "Undo reopens the chooser (\(format(reopened)))")
        for id in ids {
            let location = await locate(id)
            check(location == .gone, "the uploaded copy is deleted (\(location))")
        }
        check(examples(folders.flowers).count == flowerExamples, "the batch's example is gone again")
        check(negatives(folders.flowers).count == flowerNegatives + 1, "and one undo negative for \(folders.flowers.name)")
        check(model.suggestions.first?.reopened == true, "the same row is back")
        await snapshot("1-reopened")

        let receiptExamples = examples(folders.receipts).count
        check(await tap("chip-\(folders.receipts.name)"), "picked the \(folders.receipts.name) chip")
        let ids2 = await waitForSent("sent to \(folders.receipts.name)")
        if let id = ids2.first {
            let location = await locate(id)
            check(location == .at([folders.receipts.id]), "drive has it in \(folders.receipts.name) (\(location))")
        }
        check(examples(folders.receipts).count == receiptExamples + 1 && examples(folders.receipts).last == 2,
              "learn: corrected, w=2 (\(examples(folders.receipts)))")
        check(negatives(folders.flowers).count == flowerNegatives + 1, "no second negative for \(folders.flowers.name) (\(negatives(folders.flowers)))")
    }

    // a chip that isn't the top: corrected, w=2, and a 0.5 negative for the top
    func cardChip() async {
        guard folders() != nil else { return }
        pointerInside()
        await dropAndWait([resumePDF()])
        guard let row = model.suggestions.first, let top = row.top, row.level != .noIdea, row.ranked.count > 1 else {
            check(false, "the resume needs a suggestion to pick against (\(model.suggestions.first.map(describe) ?? "no row"))")
            return
        }
        print("  \(describe(row))")
        let alternative = row.ranked[1].destination
        let before = examples(alternative).count
        let topNegatives = negatives(top)
        await snapshot("1-card")
        check(await tap("chip-\(alternative.name)"), "picked the \(alternative.name) chip instead of \(top.name)")
        let ids = await waitForSent("sent to \(alternative.name)")
        if let id = ids.first {
            let location = await locate(id)
            check(location == .at([alternative.id]), "drive has it in \(alternative.name) (\(location))")
        }
        check(examples(alternative).count == before + 1 && examples(alternative).last == 2, "corrected, w=2 (\(examples(alternative)))")
        check(negatives(top) == topNegatives + [0.5], "neg=\(top.name):0.5 (\(negatives(top)))")
    }

    // 3 mixed files: rows in drop order, change one row, Send all puts each in its folder (no zip), Undo deletes all 3
    func cardMulti() async {
        guard let folders = folders() else { return }
        pointerInside()
        let files = [sunflower, resumePDF(), receiptPNG()]
        await dropAndWait(files)
        check(model.suggestions.map(\.file.name) == files.map(\.lastPathComponent), "rows in drop order: \(model.suggestions.map(\.file.name))")
        for row in model.suggestions {
            print("  \(describe(row))")
        }
        await snapshot("1-card")

        let expected = [folders.flowers, folders.resumes, folders.receipts]
        // change one row through its menu: the receipt goes to Receipts
        let picked = await pick(folders.receipts.name, fromMenu: "row-2")
        check(picked, "picked \(folders.receipts.name) from the receipt row's menu")
        if !picked {
            model.choose(folders.receipts, for: model.suggestions[2].id)
        }
        // whatever else wasn't preselected right (send all needs a folder on every row)
        for (index, row) in model.suggestions.enumerated() where row.chosen?.id != expected[index].id {
            let fixed = await pick(expected[index].name, fromMenu: "row-\(index)")
            check(fixed, "row \(index): picked \(expected[index].name) (was \(row.chosen?.name ?? "nothing"))")
        }
        check(model.suggestions[2].touched, "the changed row counts as picked")
        check(model.canSendAll, "Send all is enabled")
        await snapshot("2-picked")

        check(await tap("sendAll"), "clicked Send all")
        let ids = await waitForSent("sent all")
        check(model.sentSummary == "Sent 3 files", "shows \"\(model.sentSummary ?? "-")\" with Undo")
        await snapshot("3-sent")
        check(ids.count == 3, "3 uploads (\(ids.count))")
        for (index, id) in ids.enumerated() where index < 3 {
            let file = try? await drive.getFile(id: id)
            check(file?.parents == [expected[index].id] && file?.name == files[index].lastPathComponent,
                  "\(files[index].lastPathComponent) is in \(expected[index].name), not zipped (\(file?.name ?? "-"))")
        }
        check(await tap("undo"), "clicked Undo")
        let reopened = await waitFor(20) { self.model.cardState == .suggesting }
        check(reopened != nil, "Undo reopens the card (\(format(reopened)))")
        for id in ids {
            let location = await locate(id)
            check(location == .gone, "undo deleted \(id) (\(location))")
        }
        check(await tap("dismiss"), "✕")
    }

    // a dropped folder is one <name>.zip row, and Send puts the zip in the chosen folder
    func cardFolder() async {
        guard let folders = folders() else { return }
        pointerInside()
        let folder = outDir.appendingPathComponent("Tax Receipts 2024", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("scan_0912.png"))
        try? FileManager.default.copyItem(at: receiptPNG(), to: folder.appendingPathComponent("scan_0912.png"))
        try? Data(TestFiles.receiptText.utf8).write(to: folder.appendingPathComponent("receipt.txt"))
        await dropAndWait([folder])
        check(model.suggestions.map(\.displayName) == ["Tax Receipts 2024.zip"], "one row: \(model.suggestions.map(\.displayName))")
        guard let row = model.suggestions.first else { return }
        print("  \(describe(row))")
        await snapshot("1-card")
        // into Receipts: Send if that's the suggestion, else its chip
        if row.top?.id == folders.receipts.id && row.level != .noIdea {
            check(await tap("send"), "clicked Send")
        } else {
            check(await tap("chip-\(folders.receipts.name)"), "picked the \(folders.receipts.name) chip")
        }
        let ids = await waitForSent("sent")
        if let id = ids.first {
            let file = try? await drive.getFile(id: id)
            check(file?.name == "Tax Receipts 2024.zip" && file?.parents == [folders.receipts.id],
                  "drive has \(file?.name ?? "-") in \(folders.receipts.name)")
        }
    }

    // Just upload: one zip into my drive, "Uploaded to My Drive", nothing learned
    func cardJustUpload() async {
        pointerInside()
        await dropAndWait([sunflower, resumePDF()])
        let learned = learnedSummary()
        let previous = model.lastUploadedFile?.id
        check(await tap("justUpload"), "clicked Just upload")
        let done = await waitFor(40) { self.model.cardState == .idle && self.model.status?.kind == .success }
        check(done != nil && model.status?.message == "Uploaded to My Drive", "shows \"\(model.status?.message ?? "-")\" (\(format(done)))")
        await snapshot("1-result")
        if let file = model.lastUploadedFile, file.id != previous {
            pendingDeletes.append(file.id)
            let root = try? await drive.getFile(id: "root")
            let remote = try? await drive.getFile(id: file.id, fields: "id,name,parents,mimeType,size")
            let parents = remote?.parents ?? []
            let bytes = Int(remote?.size ?? "") ?? 0
            print("  uploaded \(file.name), \(bytes) bytes, parents \(parents), my drive root \(root?.id ?? "not readable")")
            let destinationIds = Set(app.destinationStore.destinations.map(\.id))
            let inRoot = root.map { parents == [$0.id] } ?? (parents.count == 1 && !destinationIds.contains(parents[0]))
            check(file.name.hasSuffix(".zip") && inRoot, "one zip in My Drive: \(file.name)")
            // Sunflower.heic is a symlink: the zip must hold the photo, not the link
            check(bytes > 60_000, "the zip has the real photo in it (\(bytes) bytes; the photo alone is 75,842)")
        } else {
            check(false, "an upload happened")
        }
        check(learnedSummary() == learned, "nothing learned")
    }

    // ✕: nothing uploaded, nothing learned
    func cardDismiss() async {
        pointerInside()
        await dropAndWait([resumePDF()])
        let learned = learnedSummary()
        let previous = model.lastUploadedFile?.id
        check(await tap("dismiss"), "clicked ✕")
        let gone = await waitFor(2) { self.model.cardState == .idle && self.model.suggestions.isEmpty }
        check(gone != nil, "the card is gone")
        try? await Task.sleep(for: .seconds(1))
        check(model.lastUploadedFile?.id == previous, "nothing uploaded")
        check(learnedSummary() == learned, "nothing learned")
    }

    // the card and "Sent [Undo]" keep the island open: pointer away, a window or text drag elsewhere,
    // a file drag between finder windows (the card comes back after it)
    func cardHold() async {
        guard folders() != nil, let monitor = DebugHooks.dragMonitor else {
            check(false, "drag monitor hook")
            return
        }
        pointerInside()
        await dropAndWait([sunflower])
        pointerOutside()
        try? await Task.sleep(for: .seconds(1.2))
        check(model.currentState == .expanded, "pointer away: the card keeps the island open")

        // dragging a window or selecting text in another app: a drag that isn't files
        monitor.isDraggingAnything = true
        try? await Task.sleep(for: .seconds(1))
        monitor.isDraggingAnything = false
        try? await Task.sleep(for: .seconds(1))
        check(model.currentState == .expanded && model.cardState == .suggesting, "a window or text drag elsewhere: still open")

        // a file dragged from one finder window to another
        monitor.isDraggingAnything = true
        monitor.isDraggingFiles = true
        try? await Task.sleep(for: .seconds(0.5))
        await snapshot("1-drop-zone")
        monitor.isDraggingFiles = false
        monitor.isDraggingAnything = false
        try? await Task.sleep(for: .seconds(1))
        check(model.currentState == .expanded && model.cardState == .suggesting, "after a finder drag: the card is back, island open")
        await snapshot("2-card-back")

        // the same while "Sent [Undo]" is up, and the drag pauses the undo window
        pointerInside()
        check(await tap("send"), "clicked Send")
        _ = await waitForSent("sent")
        pointerOutside()
        try? await Task.sleep(for: .seconds(1))
        check(model.currentState == .expanded && isSent, "pointer away: Undo keeps the island open")
        monitor.isDraggingAnything = true
        monitor.isDraggingFiles = true
        try? await Task.sleep(for: .seconds(6))
        check(isSent, "a finder drag longer than the undo window: Undo is still there behind the drop zone")
        monitor.isDraggingFiles = false
        monitor.isDraggingAnything = false
        let back = Date()
        try? await Task.sleep(for: .seconds(1))
        check(model.currentState == .expanded && isSent, "after the drag: Undo is back")
        await snapshot("3-undo-back")
        let ended = await waitFor(8) { self.model.cardState == .idle }
        let after = Date().timeIntervalSince(back)
        check(ended != nil && after > 4.5 && after < 6.5, "its 5 s started over when it came back (ended \(format(after)) later)")
    }

    // resolving the card with the pointer already outside closes the island within ~0.5 s
    func cardRelease() async {
        guard folders() != nil else { return }
        pointerInside()
        await dropAndWait([sunflower])
        pointerOutside()
        try? await Task.sleep(for: .milliseconds(800))
        check(model.currentState == .expanded, "the card holds the island open")
        check(await tap("dismiss"), "clicked ✕")
        let closed = await waitFor(2) { self.model.currentState == .collapsed }
        check(closed != nil && closed! < 0.6, "✕ with the pointer outside: closed after \(format(closed))")

        pointerInside()
        model.expand()
        await dropAndWait([sunflower])
        check(await tap("send"), "clicked Send")
        _ = await waitForSent("sent")
        pointerOutside()
        _ = await waitFor(8) { self.model.cardState == .idle }
        let closed2 = await waitFor(2) { self.model.currentState == .collapsed }
        check(closed2 != nil && closed2! < 0.6, "undo window ran out with the pointer outside: closed after \(format(closed2))")
    }

    // an untouched card folds away after 30 s; hovering the notch brings it back
    func cardUnattended() async {
        pointerInside()
        await dropAndWait([resumePDF()])
        let shown = Date()
        pointerOutside()
        let parked = await waitFor(40) { self.model.parked && self.model.currentState == .collapsed }
        let after = Date().timeIntervalSince(shown)
        check(parked != nil && after > 29 && after < 33, "an untouched card folds away after ~30 s (\(format(after)))")
        check(model.cardState == .suggesting && !model.suggestions.isEmpty, "the card is kept while folded")
        // the hover timer sees the pointer on the notch
        DebugPointer.override = NSPoint(x: window.pillFrame.midX, y: window.pillFrame.midY)
        let back = await waitFor(2) { self.model.currentState == .expanded }
        check(back != nil && model.holdsExpanded && model.cardState == .suggesting, "hovering the notch brings the card back (\(format(back)))")
        await snapshot("1-back")
        check(await tap("dismiss"), "✕")
    }

    // with no destinations a drop goes to the old cube grid
    func cardNoDestinations() async {
        let store = app.destinationStore
        let saved = store.destinations
        for destination in saved {
            store.remove(destination.id)
        }
        pointerInside()
        model.expand()
        drop([resumePDF()])
        check(model.cardState == .idle, "no card without destinations")
        let queued = await waitFor(3) { self.model.droppedFiles.count == 1 }
        check(queued != nil, "the file waits in the cube grid")
        let grid = await waitFor(2) { DebugFrames.frames["cube-upload"] != nil }
        check(grid != nil, "the cube grid shows")
        await snapshot("1-grid")
        model.clearFiles()
        for destination in saved {
            store.add(destination)
        }
    }

    // MARK: two launches: hints and learning survive a relaunch

    // Box A and Box B: a resume ranks nowhere in particular; Box B's hint (Return) makes it first.
    // Box A's hint is committed by focus leaving the field, then cleared again
    func cardHint() async {
        let store = app.destinationStore
        let saved = store.destinations
        check(!saved.isEmpty && saved.allSatisfy { $0.hint == nil }, "your saved destinations (no hints yet) load: \(saved.map(\.name))")
        for destination in saved {
            store.remove(destination.id)
        }
        store.add(Destination(id: "scenario-box-a", name: "Box A", path: "My Drive / Box A"))
        store.add(Destination(id: "scenario-box-b", name: "Box B", path: "My Drive / Box B"))
        pointerInside()
        await dropAndWait([resumePDF()])
        if let row = model.suggestions.first {
            print("  before the hint: \(describe(row))")
        }
        check(await tap("dismiss"), "✕")

        guard let setup = await openSetupWindow() else { return }
        check(await type(Self.boxB, into: "hint-Box B", in: setup, pressReturn: true), "typed Box B's hint and pressed Return")
        let committed = await waitFor(2) { store.destinations.first { $0.name == "Box B" }?.hint == Self.boxB }
        check(committed != nil, "Return saved it")
        check(await type("my receipts", into: "hint-Box A", in: setup, pressReturn: false), "typed into Box A without Return")
        check(store.destinations.first { $0.name == "Box A" }?.hint == nil, "not saved per keystroke")
        // clicking into another field takes the focus away
        check(await tap("hint-Box B", in: setup), "clicked into Box B's field")
        let blurred = await waitFor(2) { store.destinations.first { $0.name == "Box A" }?.hint == "my receipts" }
        check(blurred != nil, "saved when focus left the field")
        check(store.destinations.first { $0.name == "Box B" }?.hint == Self.boxB, "Box B's hint untouched")
        check(await type("", into: "hint-Box A", in: setup, pressReturn: true), "cleared Box A's hint")
        let cleared = await waitFor(2) { store.destinations.first { $0.name == "Box A" }?.hint == nil }
        check(cleared != nil, "an empty hint is no hint")
        await snapshot("1-setup", of: setup)
        setup.close()

        await dropAndWait([resumePDF()])
        if let row = model.suggestions.first {
            print("  with the hint: \(describe(row))")
            check(row.top?.name == "Box B", "Box B ranks first now")
        }
        await snapshot("2-card")
        check(await tap("dismiss"), "✕")
        // your folders back next to the boxes, for learning-write and the relaunch
        for destination in saved {
            store.add(destination)
        }
    }

    func cardHintRelaunch() async {
        let store = app.destinationStore
        print("  loaded: \(store.destinations.map { "\($0.name)\($0.hint.map { " (\($0))" } ?? "")" })")
        check(store.destinations.first { $0.name == "Box B" }?.hint == Self.boxB, "Box B's hint survived the relaunch")
        // learning-read removed resumes on purpose; the others are still there
        check(store.destinations.contains { $0.name.lowercased() == "flowers" }, "the older saved folders load next to it")
        guard let setup = await openSetupWindow(), let content = setup.contentView else { return }
        check(textFields(in: content).contains { $0.stringValue == Self.boxB }, "the setup window shows the hint")
        await snapshot("1-setup", of: setup)
        setup.close()
    }

    // one Send all, then quit the normal way: the quit's flush has to save it (nothing is on disk yet)
    func learningWrite() async {
        guard let folders = folders(), let url = DebugScenarios.learningFileURL else { return }
        pointerInside()
        await dropAndWait([sunflower, resumePDF()])
        model.choose(folders.flowers, for: model.suggestions[0].id)
        model.choose(folders.resumes, for: model.suggestions[1].id)
        check(await tap("sendAll"), "clicked Send all")
        let ids = await waitForSent("sent 2 files")
        check(examples(folders.flowers).count == 1 && examples(folders.resumes).count == 1, "learned one example each")
        // the relaunch deletes the uploads: deleting them now would give the debounced save time to run
        try? ids.joined(separator: "\n").write(to: outDir.appendingPathComponent("pending-delete.txt"), atomically: true, encoding: .utf8)
        pendingDeletes = []
        let onDisk = LearningStore(fileURL: url)
        check(onDisk.data(for: folders.resumes.id) == nil, "not saved yet when quitting (the debounced write hasn't run)")
        // straight to quitting: a click's wait could let the debounced save run first
        model.dismissCard()
        quitNormally = true
        print("  quitting through NSApp.terminate")
    }

    // after the relaunch: the data is there; removing a destination drops its data; Reset clears the rest
    func learningRead() async {
        guard let folders = folders(), let store = app.learningStore, let url = DebugScenarios.learningFileURL else { return }
        let pending = outDir.appendingPathComponent("pending-delete.txt")
        if let text = try? String(contentsOf: pending, encoding: .utf8) {
            pendingDeletes += text.split(separator: "\n").map(String.init)
            try? FileManager.default.removeItem(at: pending)
        }
        check(examples(folders.flowers).count == 1 && examples(folders.resumes).count == 1,
              "what was learned before quitting is back (\(learnedSummary()))")
        guard let setup = await openSetupWindow() else { return }
        await snapshot("1-setup", of: setup)
        check(await tap("remove-\(folders.resumes.name)", in: setup), "clicked remove on \(folders.resumes.name)")
        let removed = await waitFor(2) { !self.app.destinationStore.contains(folders.resumes.id) }
        check(removed != nil, "it left the list")
        let dropped = await waitFor(2) { store.data(for: folders.resumes.id) == nil }
        check(dropped != nil, "its learned data went with it")
        check(examples(folders.flowers).count == 1, "the others keep theirs")
        check(await tap("resetLearning", in: setup), "clicked Reset learning…")
        check(await tap("resetConfirm", in: setup), "confirmed inline")
        let reset = await waitFor(3) { store.snapshot().isEmpty && !FileManager.default.fileExists(atPath: url.path) }
        check(reset != nil, "everything learned is gone, the file too")
        await snapshot("2-reset", of: setup)
        setup.close()
    }

    // the plan §5 step 6 behavior checks that don't need a person's own drag
    func hoverBehavior() async {
        // a cube dragged and let go somewhere that isn't a cube: cleared once the button is up
        model.draggedCube = .upload
        let cleared = await waitFor(2) { self.model.draggedCube == nil }
        check(cleared != nil, "a cube drag let go elsewhere goes back to normal (\(format(cleared)))")

        // moving the real cursor would get in the way of someone using the mac
        guard secondsSinceUserInput() >= 20 else {
            print("  skip: someone used the mouse or keyboard in the last 20 s, not moving the cursor")
            return
        }
        let original = NSEvent.mouseLocation
        let pill = window.pillFrame
        let screen = NSScreen.screens.first?.frame ?? .zero
        let away = NSPoint(x: screen.minX + 200, y: screen.midY)

        // with this app in front (the Destinations window key), only the poll sees the pointer
        model.collapse()
        _ = await waitFor(2) { self.model.currentState == .collapsed }
        if let setup = await openSetupWindow() {
            CGWarpMouseCursorPosition(CGPoint(x: pill.midX, y: screen.maxY - pill.midY))   // no event at all
            let expanded = await waitFor(1.5) { self.model.currentState == .expanded }
            check(expanded != nil, "Destinations window in front: hovering the notch still expands it (\(format(expanded)))")
            CGWarpMouseCursorPosition(CGPoint(x: away.x, y: screen.maxY - away.y))
            let collapsed = await waitFor(2) { self.model.currentState == .collapsed }
            check(collapsed != nil, "and moving away collapses it (\(format(collapsed)))")
            setup.close()
        }

        // a drag that isn't files (a window, selected text) passing near the notch: the proximity timer
        model.collapse()
        _ = await waitFor(2) { self.model.currentState == .collapsed }
        CGWarpMouseCursorPosition(CGPoint(x: pill.midX, y: screen.maxY - pill.midY - 30))
        DebugHooks.dragMonitor?.isDraggingAnything = true
        let near = await waitFor(1.5) { self.model.currentState == .expanded }
        check(near != nil, "a non-finder drag near the notch expands it (\(format(near)))")
        DebugHooks.dragMonitor?.isDraggingAnything = false
        CGWarpMouseCursorPosition(CGPoint(x: original.x, y: screen.maxY - original.y))
    }

    // dropToRank per kind (the plan §4.8): cold after 12 s of nothing, and with a finder drag's pre-warm
    // starting 0.7 s before the drop. fresh copies every time, so nothing comes from the cache. and memory:
    // the peak while 5 mixed files classify, 60 s later, and 10 s after a drag that didn't drop here
    func dropTiming() async {
        guard folders() != nil, let monitor = DebugHooks.dragMonitor else {
            check(false, "drag monitor hook")
            return
        }
        // the targets are for an optimized build, launched with --check-timing
        let optimized = CommandLine.arguments.contains("--check-timing")
        print("  build: \(optimized ? "optimized, checked" : "timings printed, not checked"), memory at start \(String(format: "%.1f", physFootprintMB())) MB")
        pointerInside()
        let dir = outDir.appendingPathComponent("timing", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var counter = 0
        func fresh(_ ext: String, _ write: (URL) -> Void) -> URL {
            counter += 1
            let url = dir.appendingPathComponent("file\(counter).\(ext)")
            write(url)
            return url
        }
        let photo = URL(fileURLWithPath: "/Library/User Pictures/Flowers/Dahlia.heic").resolvingSymlinksInPath()
        let kinds: [(name: String, ext: String, budget: Double, write: (URL) -> Void)] = [
            ("photo (heic)", "heic", 100, { try? FileManager.default.copyItem(at: photo, to: $0) }),
            ("text pdf", "pdf", 100, { TestFiles.writeTextPDF(Self.resumeText, to: $0) }),
            ("scanned pdf", "pdf", 300, { TestFiles.writeImagePDF(TestFiles.renderText(TestFiles.receiptText, width: 1200, height: 1700, fontSize: 44), to: $0) }),
        ]
        func timed(_ url: URL, prewarmed: Bool) async -> Double? {
            if prewarmed {
                monitor.isDraggingAnything = true
                monitor.isDraggingFiles = true          // what a finder drag start does: the pre-warm begins
                try? await Task.sleep(for: .milliseconds(700))
            }
            drop([url])
            let ready = await waitFor(15) {
                self.model.cardState == .suggesting && !self.model.suggestions.contains { $0.status == .classifying }
            }
            let ms = ready == nil ? nil : model.lastDropToRank
            monitor.isDraggingFiles = false
            monitor.isDraggingAnything = false
            model.dismissCard()
            try? await Task.sleep(for: .milliseconds(300))
            return ms
        }
        func text(_ ms: Double?) -> String {
            ms.map { String(format: "%.0f ms", $0) } ?? "timed out"
        }
        for kind in kinds {
            try? await Task.sleep(for: .seconds(12))
            let cold = await timed(fresh(kind.ext, kind.write), prewarmed: false)
            try? await Task.sleep(for: .seconds(12))
            let warm = await timed(fresh(kind.ext, kind.write), prewarmed: true)
            print("  dropToRank \(kind.name): cold \(text(cold)), after a drag's pre-warm \(text(warm)) (target < \(Int(kind.budget)) ms)")
            if optimized {
                check((warm ?? .infinity) < kind.budget, "\(kind.name): \(text(warm)) after pre-warm, under \(Int(kind.budget)) ms")
            }
        }
        // 5 mixed files at once: the peak, sampled every 100 ms
        let five = [fresh("heic", kinds[0].write), fresh("pdf", kinds[1].write), fresh("pdf", kinds[2].write),
                    fresh("heic", { try? FileManager.default.copyItem(at: URL(fileURLWithPath: "/Library/User Pictures/Animals/Eagle.heic").resolvingSymlinksInPath(), to: $0) }),
                    fresh("png", { TestFiles.writeImage(TestFiles.renderText(TestFiles.receiptText, width: 700, height: 1000, fontSize: 30), to: $0) })]
        var peak = physFootprintMB()
        drop(five)
        _ = await waitFor(20) {
            peak = max(peak, physFootprintMB())
            return self.model.cardState == .suggesting && !self.model.suggestions.contains { $0.status == .classifying }
        }
        print(String(format: "  memory: peak while 5 mixed files classify %.1f MB (target < 150)", peak))
        if optimized {
            check(peak < 150, String(format: "peak memory classifying 5 files %.1f MB, under 150", peak))
        }
        model.dismissCard()
        try? await Task.sleep(for: .seconds(60))
        print(String(format: "  memory: 60 s after classifying %.1f MB", physFootprintMB()))
        // a drag that ends somewhere else
        monitor.isDraggingAnything = true
        monitor.isDraggingFiles = true
        try? await Task.sleep(for: .seconds(1))
        monitor.isDraggingFiles = false
        monitor.isDraggingAnything = false
        try? await Task.sleep(for: .seconds(10))
        print(String(format: "  memory: 10 s after a drag that wasn't dropped here %.1f MB", physFootprintMB()))
    }

    // the scratch destinations and learned file go away
    func cleanupScratch() {
        UserDefaults.standard.removePersistentDomain(forName: DebugScenarios.scratchDomain)
        if let url = DebugScenarios.learningFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        print("  removed the scratch destinations and learning file")
    }
}

// what pick(_:fromMenu:) saw, shared with its timer and notification
@MainActor
final class MenuPick {
    var menu: NSMenu?
    var titles: [String] = []
    var picked = false
    var done = false
}
#endif
