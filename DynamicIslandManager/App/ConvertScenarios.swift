#if DEBUG
import AppKit
import AVFoundation

// converting on the real island, sends go to the user's test folders and are deleted after
// save to mac only ever writes into a scratch folder of copies, never next to the user's own files
extension ScenarioRunner {
    // sunflower.heic picked as jpeg and sent, drive has a jpeg, undo takes it back
    func convertSend() async {
        guard let folders = folders() else { return }
        pointerInside()
        await dropAndWait([sunflower])
        print("  dropToRank with a format pill on the card: \(dropToRankText())")
        guard let row = model.suggestions.first else { return }
        check(row.convertOptions.contains(.jpeg), "a heic offers jpeg (\(row.convertOptions.map(\.title)))")
        check(await pick("JPEG", fromMenu: "format-0"), "picked JPEG from the pill")
        let picked = await waitFor(2) { self.model.suggestions.first?.convertTo == .jpeg }
        check(picked != nil, "the row goes as JPEG")
        await snapshot("1-picked")
        model.send(row.id, to: folders.flowers)
        let ids = await waitForSent("converted and sent")
        guard let id = ids.first else { return }
        do {
            let file = try await drive.getFile(id: id, fields: "id,name,mimeType,parents")
            check(file.name == "Sunflower.jpg" && file.mimeType == "image/jpeg", "drive has Sunflower.jpg as image/jpeg (\(file.name), \(file.mimeType ?? "-"))")
            check(file.parents == [folders.flowers.id], "in \(folders.flowers.name)")
        } catch {
            check(false, "drive has the file (\(DriveError.from(error).shortText))")
        }
        check(await tap("undo"), "clicked Undo")
        let undone = await waitFor(10) { self.model.cardState == .suggesting }
        check(undone != nil, "Undo reopens the card (\(format(undone)))")
        let location = await locate(id)
        check(location == .gone, "undo deleted the jpeg (\(location))")
        pendingDeletes.removeAll { $0 == id }
        check(await tap("dismiss"), "✕")
        _ = await waitFor(2) { self.model.cardState == .idle }
        check(!FileManager.default.fileExists(atPath: model.conversion.root.path), "the converted copy is gone with the card")
    }

    // a heic, a wav and a pdf, the first two saved to the mac, nothing uploaded or learned
    func convertSave() async {
        guard let folders = folders() else { return }
        let scratch = outDir.appendingPathComponent("convert-save", isDirectory: true)
        try? FileManager.default.removeItem(at: scratch)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let heic = scratch.appendingPathComponent("Sunflower.heic")
        try? FileManager.default.copyItem(at: sunflower.resolvingSymlinksInPath(), to: heic)
        let pdf = scratch.appendingPathComponent("doc_final2.pdf")
        try? FileManager.default.copyItem(at: resumePDF(), to: pdf)
        guard let wav = try? ConversionTests.tone(scratch, "voice memo.wav") else {
            check(false, "made a wav to convert")
            return
        }
        let learnedBefore = [folders.flowers, folders.resumes, folders.receipts].map { examples($0).count }
        // uploads are refused and counted, reset() puts the real transport back
        let uploads = NoUploads(drive.transport)
        drive.transport = uploads
        pointerInside()
        await dropAndWait([heic, wav, pdf])
        let pdfRow = model.suggestions.first { $0.file.name == "doc_final2.pdf" }
        check(pdfRow?.convertOptions.isEmpty == true, "the pdf row has no pill")
        let pdfIndex = model.suggestions.firstIndex { $0.file.name == "doc_final2.pdf" } ?? -1
        check(DebugFrames.frames["format-\(pdfIndex)"] == nil, "and no pill is drawn for it")
        let heicIndex = model.suggestions.firstIndex { $0.file.name == "Sunflower.heic" } ?? 0
        check(await pick("JPEG", fromMenu: "format-\(heicIndex)"), "picked JPEG for the photo")
        if let row = model.suggestions.first(where: { $0.file.name == "voice memo.wav" }) {
            model.setConvert(.m4a, for: row.id)
        }
        await snapshot("1-card")
        check(await tap("saveToMac"), "clicked Save to Mac")
        // the pdf stays on the card, so the card says it rather than a result
        let saved = await waitFor(30) { self.model.cardNote == "Saved 2 files to your Mac" && !self.model.savingToMac }
        check(saved != nil, "the card says \"Saved 2 files to your Mac\" (\(format(saved)))")
        await snapshot("2-saved")
        let jpg = scratch.appendingPathComponent("Sunflower.jpg")
        let m4a = scratch.appendingPathComponent("voice memo.m4a")
        check(FileManager.default.fileExists(atPath: jpg.path), "Sunflower.jpg is next to the original")
        let length = try? await AVURLAsset(url: m4a).load(.duration).seconds
        check(length.map { abs($0 - 1) < 0.1 } == true, "voice memo.m4a is next to the original and plays (\(length.map { String(format: "%.2f s", $0) } ?? "-"))")
        let pdfCopies = ((try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []).filter { $0.hasPrefix("doc_final2") }
        check(pdfCopies == ["doc_final2.pdf"] && model.suggestions.map(\.file.name) == ["doc_final2.pdf"],
              "the pdf wasn't converted, it's still on the card to send (\(pdfCopies))")
        LinkActions.opened = []
        check(await tap("showSaved"), "clicked Show in Finder")
        // compared as resolved paths, the out folder can come with a double slash
        let wanted = Set([jpg, m4a].map { $0.resolvingSymlinksInPath().path })
        let shown = await waitFor(2) { Set(LinkActions.opened.map { $0.resolvingSymlinksInPath().path }) == wanted }
        check(shown != nil, "it would show both in Finder")
        check(uploads.attempts == 0, "nothing was uploaded (\(uploads.attempts) upload requests)")
        let learnedAfter = [folders.flowers, folders.resumes, folders.receipts].map { examples($0).count }
        check(learnedAfter == learnedBefore, "nothing was learned (\(learnedBefore) then \(learnedAfter))")

        // the pdf stayed on its own card
        if model.cardState != .idle {
            check(await tap("dismiss"), "✕ on the pdf left behind")
        }
        _ = await waitFor(4) { self.model.cardState == .idle }
        model.debugResetStatus()
        await dropAndWait([heic])
        if let row = model.suggestions.first {
            model.setConvert(.jpeg, for: row.id)
        }
        model.saveToMac()
        let again = await waitFor(30) { FileManager.default.fileExists(atPath: scratch.appendingPathComponent("Sunflower 2.jpg").path) }
        check(again != nil, "a second save names it Sunflower 2.jpg")
        // with nothing else on the card it ends as a result
        let result = await waitFor(5) { self.model.status?.message == "Saved 1 file" && self.model.status?.reveal.count == 1 }
        check(result != nil, "and shows \"Saved 1 file\" with Show in Finder")
        await snapshot("3-result")
        check(uploads.attempts == 0, "the second save uploaded nothing either")
        // show in finder holds the result while the pointer is on it
        pointerOutside()
        _ = await waitFor(6) { self.model.cardState == .idle && self.model.status == nil }
    }

    // a conversion that fails fails its row only, retry sends it
    func convertError() async {
        guard let folders = folders() else { return }
        let scratch = outDir.appendingPathComponent("convert-error", isDirectory: true)
        try? FileManager.default.removeItem(at: scratch)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        guard let wav = try? ConversionTests.tone(scratch, "take two.wav") else {
            check(false, "made a wav to convert")
            return
        }
        pointerInside()
        await dropAndWait([sunflower, wav])
        for row in model.suggestions {
            model.setConvert(row.file.name == "Sunflower.heic" ? .jpeg : .m4a, for: row.id)
            model.choose(row.file.name == "Sunflower.heic" ? folders.flowers : folders.resumes, for: row.id)
        }
        ConversionService.failOnce = ["take two.wav"]
        defer { ConversionService.failOnce = [] }
        model.sendAll()
        let failed = await waitFor(30) { if case .error = self.model.cardState { return true }; return false }
        check(failed != nil, "the send ends with an error card (\(format(failed)))")
        let wavRow = model.suggestions.first { $0.file.name == "take two.wav" }
        if case .failed(let why) = wavRow?.status {
            check(why.hasPrefix("Couldn't convert"), "only the wav failed: \(why)")
        } else {
            check(false, "only the wav failed (\(String(describing: wavRow?.status)))")
        }
        check(model.suggestions.first { $0.file.name == "Sunflower.heic" }?.isSent == true, "the photo still went")
        await snapshot("1-error")
        check(await tap("retry"), "clicked Retry")
        let ids = await waitForSent("retry sends the wav")
        check(ids.count == 2, "both are in drive now (\(ids.count))")
        if let id = model.suggestions.first(where: { $0.file.name == "take two.wav" })?.sentFileId,
           let file = try? await drive.getFile(id: id, fields: "id,name,mimeType") {
            check(file.name == "take two.m4a", "as take two.m4a (\(file.name))")
        }
    }
}
#endif
