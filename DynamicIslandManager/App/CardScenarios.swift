#if DEBUG
import AppKit
import SwiftUI

// suggestion card checks on the real island, real sign-in and drive folders
// drops go through handleDrop, clicks go to the card's real buttons
// every upload gets deleted again (undo or reset)
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

    // MARK: folders and test files

    var flowers: Destination? { destination(named: "flowers") }
    var resumes: Destination? { destination(named: "resumes") }
    var receipts: Destination? { destination(named: "reciepts") ?? destination(named: "receipts") }

    func destination(named name: String) -> Destination? {
        app.destinationStore.destinations.first { $0.name.lowercased() == name }
    }

    // the 3 folders these checks send to, fails if one is missing
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

    // resume with a useless name like doc_final2.pdf
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

    // drop and wait for every row's suggestion
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

    // keep the island open without moving the real cursor
    func pointerInside() {
        DebugPointer.override = NSPoint(x: window.islandFrame.midX, y: window.islandFrame.minY + 40)
    }

    func pointerOutside() {
        let screen = NSScreen.screens.first?.frame ?? .zero
        DebugPointer.override = NSPoint(x: screen.minX + 200, y: screen.midY)
    }

    // wait for the control to settle, then click it
    func tap(_ control: String, in target: NSWindow? = nil) async -> Bool {
        guard await waitFor(2, { DebugFrames.frames[control] != nil }) != nil else {
            print("  no frame for \(control)")
            return false
        }
        try? await Task.sleep(for: .milliseconds(450))
        return click(control, in: target ?? window)
    }

    // send, wait for "Sent", remember uploads for cleanup
    func waitForSent(_ what: String, within seconds: Double = 40) async -> [String] {
        let sent = await waitFor(seconds) { self.isSent }
        check(sent != nil, "\(what) (\(format(sent)))")
        let ids = model.suggestions.compactMap(\.sentFileId)
        pendingDeletes += ids
        return ids
    }

    // open a swiftui Menu with a click and pick an item
    // menus run their own event loop, a common modes timer still fires in there
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

    // click into the field, type, then Return (optional)
    // the window shares one field editor, wait until it belongs to this field
    func type(_ text: String, into control: String, in target: NSWindow, pressReturn: Bool) async -> Bool {
        guard await tap(control, in: target), let field = textField(at: control, in: target) else { return false }
        func editorOfField() -> NSTextView? {
            (target.firstResponder as? NSTextView).flatMap { $0.delegate === field ? $0 : nil }
        }
        var editor = await waitForValue(1, editorOfField)
        if editor == nil {
            // window wasn't key so the click didn't focus it, do it directly
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

    // find the NSTextField behind a swiftui TextField
    // compare in window coords, the hosting view is flipped
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

    // open the setup window and wait until it takes clicks
    // an inactive app's first click only activates the window
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

    // example and negative counts per destination, to check nothing was learned
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

    // a folder renamed in drive shows its new name after sign-in
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

    // sunflower photo goes to flowers, Send puts it there
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

    // undo deletes the copy, then picking receipts is a correction (w=2)
    // and flowers doesn't get a second negative
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

    // picking a chip that isn't the top is a correction, top gets a 0.5 negative
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

    // 3 mixed files, send all puts each in its own folder, undo deletes all 3
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
        // change one row with its menu, receipt goes to receipts
        let picked = await pick(folders.receipts.name, fromMenu: "row-2")
        check(picked, "picked \(folders.receipts.name) from the receipt row's menu")
        if !picked {
            model.choose(folders.receipts, for: model.suggestions[2].id)
        }
        // fix any other rows, send all needs a folder on each
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

    // a dropped folder becomes one zip row
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
        // send to receipts, through Send or its chip
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

    // just upload, one zip into my drive and nothing learned
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
            // Sunflower.heic is a symlink, the zip needs the actual photo
            check(bytes > 60_000, "the zip has the real photo in it (\(bytes) bytes; the photo alone is 75,842)")
        } else {
            check(false, "an upload happened")
        }
        check(learnedSummary() == learned, "nothing learned")
    }

    // close button, nothing uploaded or learned
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

    // card and "Sent [Undo]" keep the island open, even with the pointer away
    // or during other drags (card comes back after a finder drag)
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

        // window or text drag in another app, not files
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

        // same while "Sent [Undo]" is up, the drag pauses the undo timer
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

    // pointer already outside, island closes about 0.5 s after the card is done
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

    // untouched card folds away after 30 s, hovering the notch brings it back
    func cardUnattended() async {
        pointerInside()
        await dropAndWait([resumePDF()])
        let shown = Date()
        pointerOutside()
        let parked = await waitFor(40) { self.model.parked && self.model.currentState == .collapsed }
        let after = Date().timeIntervalSince(shown)
        check(parked != nil && after > 29 && after < 33, "an untouched card folds away after ~30 s (\(format(after)))")
        check(model.cardState == .suggesting && !model.suggestions.isEmpty, "the card is kept while folded")
        // hover sees the pointer on the notch
        DebugPointer.override = NSPoint(x: window.pillFrame.midX, y: window.pillFrame.midY)
        let back = await waitFor(2) { self.model.currentState == .expanded }
        check(back != nil && model.holdsExpanded && model.cardState == .suggesting, "hovering the notch brings the card back (\(format(back)))")
        await snapshot("1-back")
        check(await tap("dismiss"), "✕")
    }

    // a 50 MB file goes up resumable, the card's progress moves, snapshots at two points
    func cardProgress() async {
        guard let folders = folders() else { return }
        pointerInside()
        let url = outDir.appendingPathComponent("dim-scenario-50mb.bin")
        if (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) != 52_428_800 {
            var bytes = [UInt8](repeating: 0, count: 52_428_800)
            for index in stride(from: 0, to: bytes.count, by: 4096) {
                bytes[index] = UInt8(truncatingIfNeeded: index >> 12)
            }
            try? Data(bytes).write(to: url)
        }
        await dropAndWait([url])
        guard let row = model.suggestions.first else { return }
        model.send(row.id, to: folders.flowers)
        let early = await waitFor(60) { (self.model.suggestions.first?.progress ?? 0) >= 0.2 }
        let first = model.suggestions.first?.progress ?? 0
        await snapshot("1-early")
        check(early != nil, String(format: "progress shows on the card (%.0f%% after %@)", first * 100, format(early)))
        let later = await waitFor(90) { (self.model.suggestions.first?.progress ?? 0) >= first + 0.3 }
        let second = model.suggestions.first?.progress ?? 0
        await snapshot("2-later")
        check(later != nil && second > first, String(format: "and moves on (%.0f%% to %.0f%%)", first * 100, second * 100))
        var ids = await waitForSent("the 50 MB file is sent", within: 300)
        if ids.isEmpty, let row = model.suggestions.first, row.isSending {
            // too slow, stopped so nothing keeps uploading into the next scenario
            model.cancelSend(row.id)
            _ = await waitFor(30) { self.model.suggestions.first?.isSending != true }
            ids = model.suggestions.compactMap(\.sentFileId)
            pendingDeletes += ids
        }
        guard let id = ids.first else { return }
        do {
            let file = try await drive.getFile(id: id, fields: "id,name,parents,size")
            check(file.parents == [folders.flowers.id] && file.size == "52428800", "drive has all 50 MB in \(folders.flowers.name)")
        } catch {
            check(false, "drive has the file (\(DriveError.from(error).shortText))")
        }
    }

    // with no destinations a drop still opens the card, with just upload and choose folders
    func cardNoDestinations() async {
        let store = app.destinationStore
        let saved = store.destinations
        for destination in saved {
            store.remove(destination.id)
        }
        pointerInside()
        await dropAndWait([resumePDF()])
        check(model.suggestions.count == 1 && !model.hasDestinations, "the card shows the file without any folders")
        let offered = await waitFor(2) { DebugFrames.frames["chooseFolders"] != nil && DebugFrames.frames["justUpload"] != nil }
        check(offered != nil, "it offers Choose folders… and Just upload")
        await snapshot("1-card")
        check(await tap("chooseFolders"), "clicked Choose folders…")
        let opened = await waitFor(2) { self.app.destinationsWindow?.isVisible == true }
        check(opened != nil, "the Destinations window opens (\(format(opened)))")
        check(model.cardState == .suggesting, "the card stays")
        app.destinationsWindow?.close()
        // folders coming back rank the waiting file
        for destination in saved {
            store.add(destination)
        }
        let ranked = await waitFor(5) { self.model.suggestions.first.map { !$0.ranked.isEmpty } ?? false }
        check(ranked != nil, "adding folders gives the file suggestions (\(format(ranked)))")
        check(await tap("dismiss"), "✕")
    }

    // MARK: hints and learning survive a relaunch

    // a resume has no clear folder until box B's hint puts it first
    // box A's hint saves when focus leaves, then gets cleared
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
        // put the real folders back next to the boxes for the relaunch
        for destination in saved {
            store.add(destination)
        }
    }

    func cardHintRelaunch() async {
        let store = app.destinationStore
        print("  loaded: \(store.destinations.map { "\($0.name)\($0.hint.map { " (\($0))" } ?? "")" })")
        check(store.destinations.first { $0.name == "Box B" }?.hint == Self.boxB, "Box B's hint survived the relaunch")
        // learning-read removed resumes on purpose, the others stay
        check(store.destinations.contains { $0.name.lowercased() == "flowers" }, "the older saved folders load next to it")
        guard let setup = await openSetupWindow(), let content = setup.contentView else { return }
        check(textFields(in: content).contains { $0.stringValue == Self.boxB }, "the setup window shows the hint")
        await snapshot("1-setup", of: setup)
        setup.close()
    }

    // send all then quit normally, the save on quit has to write it
    func learningWrite() async {
        guard let folders = folders(), let url = DebugScenarios.learningFileURL else { return }
        pointerInside()
        await dropAndWait([sunflower, resumePDF()])
        model.choose(folders.flowers, for: model.suggestions[0].id)
        model.choose(folders.resumes, for: model.suggestions[1].id)
        check(await tap("sendAll"), "clicked Send all")
        let ids = await waitForSent("sent 2 files")
        check(examples(folders.flowers).count == 1 && examples(folders.resumes).count == 1, "learned one example each")
        // delete uploads after the relaunch, now the debounced save could run first
        try? ids.joined(separator: "\n").write(to: outDir.appendingPathComponent("pending-delete.txt"), atomically: true, encoding: .utf8)
        pendingDeletes = []
        let onDisk = LearningStore(fileURL: url)
        check(onDisk.data(for: folders.resumes.id) == nil, "not saved yet when quitting (the debounced write hasn't run)")
        // quit right away so the debounced save can't run first
        model.dismissCard()
        quitNormally = true
        print("  quitting through NSApp.terminate")
    }

    // after relaunch the data is still there, remove and reset clear it
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

    // hover checks that don't need a real drag
    func hoverBehavior() async {
        // don't move the real cursor while someone is using the mac
        guard secondsSinceUserInput() >= 20 else {
            print("  skip: someone used the mouse or keyboard in the last 20 s, not moving the cursor")
            return
        }
        let original = NSEvent.mouseLocation
        let pill = window.pillFrame
        let screen = NSScreen.screens.first?.frame ?? .zero
        let away = NSPoint(x: screen.minX + 200, y: screen.midY)

        // with this app in front only the poll sees the pointer
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

        // non-file drag near the notch, proximity timer opens it
        model.collapse()
        _ = await waitFor(2) { self.model.currentState == .collapsed }
        CGWarpMouseCursorPosition(CGPoint(x: pill.midX, y: screen.maxY - pill.midY - 30))
        DebugHooks.dragMonitor?.isDraggingAnything = true
        let near = await waitFor(1.5) { self.model.currentState == .expanded }
        check(near != nil, "a non-finder drag near the notch expands it (\(format(near)))")
        DebugHooks.dragMonitor?.isDraggingAnything = false
        CGWarpMouseCursorPosition(CGPoint(x: original.x, y: screen.maxY - original.y))
    }

    // dropToRank per file type, cold (12 s idle) and pre-warmed
    // fresh copies each time so nothing is cached
    // also logs memory at peak, 60 s later, and after a drag that went elsewhere
    func dropTiming() async {
        guard folders() != nil, let monitor = DebugHooks.dragMonitor else {
            check(false, "drag monitor hook")
            return
        }
        // timing targets only count on an optimized build (--check-timing)
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
                monitor.isDraggingFiles = true          // same as a finder drag starting, pre-warm kicks off
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
        // 5 mixed files at once, peak sampled every 100 ms
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

    // remove the scratch destinations and learning file
    func cleanupScratch() {
        UserDefaults.standard.removePersistentDomain(forName: DebugScenarios.scratchDomain)
        if let url = DebugScenarios.learningFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        print("  removed the scratch destinations and learning file")
    }
}

// shared between pick(_:fromMenu:), its timer and the notification
@MainActor
final class MenuPick {
    var menu: NSMenu?
    var titles: [String] = []
    var picked = false
    var done = false
}
#endif
