import Foundation
import AppKit
import UniformTypeIdentifiers
import os

// suggestion card logic, drop -> classify -> suggest -> send -> undo, plus learning
// the state lives in IslandViewModel
extension IslandViewModel {
    static let signposter = OSSignposter(subsystem: "com.dynamicisland.manager", category: .pointsOfInterest)

    var hasDestinations: Bool {
        !destinationStore.destinations.isEmpty
    }

    // rows that still need the user's pick before "send all"
    var unpickedNoIdeaCount: Int {
        suggestions.filter { $0.level == .noIdea && $0.chosen == nil && !$0.isSent }.count
    }

    // without folders nothing can be suggested, just upload doesn't wait for the classifier
    var canJustUpload: Bool {
        cardState == .suggesting || (cardState == .classifying && !hasDestinations && !suggestions.isEmpty)
    }

    var canSendAll: Bool {
        cardState == .suggesting && !suggestions.isEmpty
            && !suggestions.contains { $0.status == .classifying || $0.status == .waiting }
            && unpickedNoIdeaCount == 0
    }

    // MARK: drops

    // called sync from .onDrop so "classifying" shows before files load
    // every drop goes to the card, without folders it offers just upload and choose folders
    func handleDrop(_ providers: [NSItemProvider]) {
        guard !providers.isEmpty else { return }
        lastDropAt = Date()
        Haptics.dropAccepted()
        let started = DispatchTime.now()
        let signpost = Self.signposter.beginInterval("dropToRank", id: Self.signposter.makeSignpostID())

        switch cardState {
        case .idle:
            cardState = .classifying
        case .sent:
            // a new drop ends the undo window and starts a new card
            commitSentBatch()
            cardState = .classifying
        case .error(_, retry: .undo):
            // undo isn't finished, new files wait until it's retried or dismissed
            break
        case .error, .suggesting:
            cardState = .classifying
        default:
            break
        }
        parked = false
        parkTask?.cancel()
        if currentState == .collapsed {
            expand()
        }

        print("drop: \(providers.count) item\(providers.count == 1 ? "" : "s")")
        let generation = cardGeneration
        Task {
            let loaded = await Self.loadFiles(providers)
            // a file from desktop/downloads waits here while macos asks for access
            let loadMs = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
            if loadMs > 1000 {
                print(String(format: "drop: files readable after %.0f ms (a permission prompt waits for an answer)", loadMs))
            }
            // card closed before the files loaded, drop them
            guard generation == cardGeneration else {
                print("drop: dismissed before its files loaded")
                Self.signposter.endInterval("dropToRank", signpost)
                return
            }
            lastDropLoad = loadMs
            addRows(loaded.items, failures: loaded.failures, drop: (started, signpost))
        }
    }

    // load in parallel, keep the drop order
    nonisolated static func loadFiles(_ providers: [NSItemProvider]) async -> (items: [FileItem], failures: Int) {
        let urls = await withTaskGroup(of: (Int, URL?).self) { group -> [URL?] in
            for (index, provider) in providers.enumerated() {
                group.addTask {
                    (index, await loadURL(provider))
                }
            }
            var results = [URL?](repeating: nil, count: providers.count)
            for await (index, url) in group {
                results[index] = url
            }
            return results
        }
        let items = urls.compactMap { $0 }.map { FileItem(url: $0) }
        return (items, urls.filter { $0 == nil }.count)
    }

    nonisolated static func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data, let string = String(data: data, encoding: .utf8), let url = URL(string: string), url.isFileURL else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: url.standardizedFileURL)
            }
        }
    }

    func addRows(_ items: [FileItem], failures: Int, drop: (DispatchTime, OSSignpostIntervalState)? = nil) {
        print("drop order: [\(items.map(\.name).joined(separator: ", "))]")
        let pending = Set(suggestions.map { $0.file.url.standardizedFileURL.path })
        var seen = pending
        var fresh: [FileSuggestion] = []
        for item in items {
            let path = item.url.standardizedFileURL.path
            // already on the card, or twice in this drop
            guard seen.insert(path).inserted else { continue }
            var row = FileSuggestion(file: item)
            row.status = newRowsWait ? .waiting : .classifying
            // the settings' defaults, the pill can still change it
            row.convertTo = ConvertDefaults.format(for: item)
            fresh.append(row)
        }
        suggestions.append(contentsOf: fresh)
        if failures > 0 {
            cardNote = "Couldn't read \(failures) file\(failures == 1 ? "" : "s")"
        }
        if suggestions.isEmpty {
            if let drop {
                Self.signposter.endInterval("dropToRank", drop.1)
            }
            cardState = failures > 0 ? .error("Couldn't read the dropped files", retry: .none) : .idle
            if cardState != .idle {
                scheduleParking()
            }
            return
        }
        classifyPending(drop: drop)
    }

    // MARK: classifying

    func classifyPending(drop: (DispatchTime, OSSignpostIntervalState)? = nil) {
        let rows = suggestions.filter { $0.status == .classifying }
        guard !rows.isEmpty else {
            finishClassifying(drop: drop)
            return
        }
        let task = Task {
            // peak memory while files are read, sampled every 100 ms
            let sampler = Task.detached { () -> Double in
                var peak = physFootprintMB()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    peak = max(peak, physFootprintMB())
                }
                return peak
            }
            let results = await extractor.extract(rows.map(\.file.url))
            sampler.cancel()
            print(String(format: "memory: peak while classifying %d file(s) %.1f MB", rows.count, await sampler.value))
            memoryLogTask?.cancel()
            memoryLogTask = Task {
                try? await Task.sleep(for: .seconds(60))
                if !Task.isCancelled {
                    logMemory("60 s after classifying")
                }
            }
            // closed while classifying, nobody wants these anymore
            guard !Task.isCancelled else { return }
            for (row, features) in zip(rows, results) {
                guard suggestions.contains(where: { $0.id == row.id }) else { continue }
                featuresById[row.id] = features
                // read now, the list may have changed while files were read
                let ranking = await classifier.rank(features, among: destinationStore.destinations)
                apply(ranking, to: row.id)
            }
            finishClassifying(drop: drop)
        }
        classifyTasks.append(task)
    }

    private func apply(_ ranking: Ranking, to id: UUID) {
        guard let index = suggestions.firstIndex(where: { $0.id == id }), !isInFlight(suggestions[index]) else { return }
        // drop folders removed while this file was being ranked
        let current = Set(destinationStore.destinations.map(\.id))
        let items = ranking.items.filter { current.contains($0.destination.id) }
        let level = items.isEmpty ? .noIdea : ranking.level
        suggestions[index].ranked = items
        suggestions[index].level = level
        suggestions[index].why = ranking.why
        if !suggestions[index].touched {
            // no idea means the user picks, otherwise preselect the top
            suggestions[index].chosen = level == .noIdea ? nil : items.first?.destination
        }
        if suggestions[index].status == .classifying {
            suggestions[index].status = .ready
        }
    }

    private func finishClassifying(drop: (DispatchTime, OSSignpostIntervalState)?) {
        guard !suggestions.contains(where: { $0.status == .classifying }) else { return }
        if cardState == .classifying {
            cardState = .suggesting
            scheduleParking()
        }
        if let (started, signpost) = drop {
            Self.signposter.endInterval("dropToRank", signpost)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
            lastDropToRank = ms
            // signpost is the full wait, the split shows how much was a permission prompt
            let load = lastDropLoad ?? 0
            print(String(format: "dropToRank: %.1f ms (%d file%@: %.1f ms getting the files, %.1f ms classifying)",
                         ms, suggestions.count, suggestions.count == 1 ? "" : "s", load, ms - load))
        }
    }

    // destinations changed while the card is open, rank again
    func destinationsChanged() {
        guard !suggestions.isEmpty else { return }
        let destinations = destinationStore.destinations
        let ids = Set(destinations.map(\.id))
        for index in suggestions.indices where !isInFlight(suggestions[index]) {
            if let chosen = suggestions[index].chosen, !ids.contains(chosen.id) {
                suggestions[index].chosen = nil
                suggestions[index].touched = false
            }
        }
        // removed choice falls back to the next ranked folder, with none left every row has no idea
        let rows = suggestions.filter {
            if case .failed = $0.status { return true }
            return $0.status == .ready
        }
        Task {
            for row in rows {
                guard let features = featuresById[row.id] else { continue }
                let ranking = await classifier.rank(features, among: destinationStore.destinations)
                apply(ranking, to: row.id)
            }
            leaveDeadResend()
        }
    }

    // a failed row whose folder is gone can't be retried, back to the chooser
    // sent stays sent, without folders the card offers just upload
    @discardableResult
    func leaveDeadResend() -> Bool {
        guard case .error(let message, retry: .resend) = cardState else { return false }
        let ids = Set(destinationStore.destinations.map(\.id))
        let dead = suggestions.contains { row in
            guard case .failed = row.status else { return false }
            return row.chosen.map { !ids.contains($0.id) } ?? true
        }
        guard dead else { return false }
        commitSentBatch()
        guard !suggestions.isEmpty else {
            clearCard()
            return true
        }
        cardNote = message
        continueWithRemainingRows()
        return true
    }

    private func isInFlight(_ row: FileSuggestion) -> Bool {
        row.isBusy || row.isSent
    }

    // the format pill, nil keeps the file as it is
    func setConvert(_ format: ConvertFormat?, for id: UUID) {
        guard let index = suggestions.firstIndex(where: { $0.id == id }), !isInFlight(suggestions[index]) else { return }
        suggestions[index].convertTo = format.flatMap { suggestions[index].convertOptions.contains($0) ? $0 : nil }
    }

    private func setStatus(_ status: RowStatus, for id: UUID) {
        if let index = suggestions.firstIndex(where: { $0.id == id }) {
            suggestions[index].status = status
        }
    }

    // MARK: choosing

    func choose(_ destination: Destination, for id: UUID) {
        guard let index = suggestions.firstIndex(where: { $0.id == id }), !isInFlight(suggestions[index]) else { return }
        suggestions[index].chosen = destination
        suggestions[index].touched = true
        parked = false
        if cardState == .suggesting {
            scheduleParking()
        }
    }

    // MARK: sending

    // one row (Send on a single file card, or picking a chip)
    func send(_ id: UUID, to destination: Destination? = nil) {
        if let destination {
            choose(destination, for: id)
        }
        guard cardState == .suggesting, let row = suggestions.first(where: { $0.id == id }), !row.isSent, row.chosen != nil else { return }
        startSend([id], viaSendAll: false)
    }

    func sendAll() {
        guard canSendAll else { return }
        startSend(suggestions.filter { !$0.isSent }.map(\.id), viaSendAll: true)
    }

    // failed rows only, same batch, so one undo covers everything
    func retrySend() {
        guard case .error(_, retry: .resend) = cardState, !leaveDeadResend() else { return }
        let failed = suggestions.filter {
            if case .failed = $0.status { return true }
            return false
        }.map(\.id)
        startSend(failed, viaSendAll: lastSendWasSendAll)
    }

    private func startSend(_ ids: [UUID], viaSendAll: Bool) {
        // lock in where each row goes so setup window edits can't change a send halfway
        let plan = ids.compactMap { id -> (UUID, Destination)? in
            guard let row = suggestions.first(where: { $0.id == id }), !row.isSent, let destination = row.chosen else { return nil }
            return (id, destination)
        }
        guard !plan.isEmpty else { return }
        parkTask?.cancel()
        undoTask?.cancel()
        for (id, _) in plan {
            if let index = suggestions.firstIndex(where: { $0.id == id }) {
                suggestions[index].status = .sending(progress: 0)
            }
        }
        cardState = .sending
        lastSendWasSendAll = viaSendAll
        let batch = batchId ?? UUID()
        batchId = batch
        let generation = cardGeneration
        Task {
            var events: [LearningEvent] = []
            var failures: [String] = []
            for (id, destination) in plan {
                guard let row = suggestions.first(where: { $0.id == id }), row.isSending else { continue }
                do {
                    let file = try await uploadRow(row, to: destination)
                    if let current = suggestions.firstIndex(where: { $0.id == id }) {
                        suggestions[current].status = .sent(fileId: file.id)
                        suggestions[current].driveLink = file.link
                    }
                    activity.record([ActivityEntry(kind: .sent, name: file.name,
                                                   convertedFrom: row.convertTo.map { _ in row.file.fileExtension.uppercased() },
                                                   bytes: file.byteCount ?? row.file.size,
                                                   driveFileId: file.id, webViewLink: file.webViewLink, destinationId: destination.id,
                                                   destinationName: destination.name, batchId: batch)])
                    if let event = learningEvent(for: row, sentTo: destination, batch: batch, viaSendAll: viaSendAll) {
                        events.append(event)
                    }
                } catch {
                    let driveError = DriveError.from(error)
                    // its x was clicked, back on the card, nothing failed or learned
                    if driveError.isCancelled {
                        if let current = suggestions.firstIndex(where: { $0.id == id }) {
                            suggestions[current].status = .ready
                        }
                        continue
                    }
                    if driveError.category == .authExpired {
                        authExpired = true
                    }
                    if let current = suggestions.firstIndex(where: { $0.id == id }) {
                        suggestions[current].status = .failed(driveError.shortText)
                    }
                    failures.append(driveError.shortText)
                }
            }
            if !events.isEmpty {
                await classifier.record(events)
            }
            // the card was cleared meanwhile, there's nothing left to finish
            guard generation == cardGeneration else { return }
            // rows back on the card missed the re-rank for folders removed while they were sending
            if suggestions.contains(where: { row in
                !isInFlight(row) && row.chosen.map { !destinationStore.contains($0.id) } == true
            }) {
                destinationsChanged()
            }
            sendFinished(batch: batch, failures: failures)
        }
    }

    // one row's upload in its own task, so its x can stop just that one
    private func uploadRow(_ row: FileSuggestion, to destination: Destination) async throws -> DriveFile {
        let id = row.id
        let report = Self.progressReporter { [weak self] fraction in
            self?.setProgress(fraction, for: [id])
        }
        let task = Task { try await self.upload(row, to: destination, progress: report) }
        uploadTasks[id] = task
        defer { uploadTasks[id] = nil }
        return try await task.value
    }

    // the x on a sending row, the upload stops and its session is forgotten
    // once every byte is in drive is finishing the file, too late to stop
    func cancelSend(_ id: UUID) {
        guard let index = suggestions.firstIndex(where: { $0.id == id }) else { return }
        let row = suggestions[index]
        guard row.status == .converting || (row.progress.map { $0 < 1 } ?? false) else { return }
        guard let task = uploadTasks[id] else {
            // not started yet, the send loop skips a row that isn't sending
            suggestions[index].status = .ready
            print("send: took a waiting row out")
            return
        }
        task.cancel()
        print("send: cancelled one row")
    }

    // drive's progress comes from urlsession's queue, about 10 updates a second reach the card
    // the clock is for tests
    nonisolated static func progressReporter(_ apply: @escaping @MainActor @Sendable (Double) -> Void,
                                             clock: @escaping @Sendable () -> CFTimeInterval = { CACurrentMediaTime() }) -> @Sendable (Double) -> Void {
        let throttle = ProgressThrottle()
        return { fraction in
            switch throttle.offer(fraction, now: clock()) {
            case .now:
                Task { @MainActor in apply(fraction) }
            case .later(let delay):
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    guard let value = throttle.takePending(now: clock()) else { return }
                    MainActor.assumeIsolated {
                        apply(value)
                    }
                }
            case .drop:
                break
            }
        }
    }

    private func setProgress(_ fraction: Double, for ids: Set<UUID>) {
        for index in suggestions.indices where ids.contains(suggestions[index].id) {
            guard let current = suggestions[index].progress, fraction > current else { continue }
            suggestions[index].status = .sending(progress: min(1, fraction))
        }
    }

    private func sendFinished(batch: UUID, failures: [String]) {
        // drive takes a moment to count what was sent
        if suggestions.contains(where: \.isSent) {
            storage.refreshSoon()
        }
        // every row was stopped with its x, nothing went
        if failures.isEmpty && !suggestions.contains(where: \.isSent) {
            batchId = nil
            continueWithRemainingRows()
            return
        }
        if failures.isEmpty {
            let sent = suggestions.filter(\.isSent)
            if sent.count == 1, let destination = sent.first?.chosen {
                sentSummary = "Sent to \(destination.name)"
            } else {
                sentSummary = "Sent \(sent.count) files"
            }
            cardState = .sent(batchId: batch)
            Haptics.sent()
            startUndoTimer()
        } else {
            let first = failures[0]
            let text = failures.count == 1 ? first : "\(failures.count) files didn't send: \(first)"
            cardState = .error(text, retry: .resend)
            scheduleParking()
            // its folder went away while it was sending
            leaveDeadResend()
        }
        classifyWaiting()
    }

    // files dropped while sending or undoing get their suggestions now
    private func classifyWaiting() {
        var waiting = false
        for index in suggestions.indices where suggestions[index].status == .waiting {
            suggestions[index].status = .classifying
            waiting = true
        }
        if waiting {
            classifyPending()
        }
    }

    private func upload(_ row: FileSuggestion, to destination: Destination, progress: @escaping @Sendable (Double) -> Void) async throws -> DriveFile {
        if let format = row.convertTo {
            // made at send time, never at drop, so ranking stays as fast
            setStatus(.converting, for: row.id)
            let converted = try await conversion.convert(row.file.url, to: format)
            try Task.checkCancellation()
            setStatus(.sending(progress: 0), for: row.id)
            return try await driveService.uploadFile(FileItem(url: converted), to: destination.id, progress: progress)
        }
        guard row.file.isDirectory else {
            return try await driveService.uploadFile(row.file, to: destination.id, progress: progress)
        }
        // folders go up as <name>.zip, zipped off main
        let file = row.file
        let zipURL = try await Self.makeZip([file])
        defer { ZipUtility.cleanupTempFile(at: zipURL) }
        return try await driveService.uploadFile(FileItem(url: zipURL), to: destination.id, progress: progress)
    }

    // learning weights per action
    func learningEvent(for row: FileSuggestion, sentTo destination: Destination, batch: UUID, viaSendAll: Bool) -> LearningEvent? {
        guard let features = featuresById[row.id] else { return nil }
        let top = row.top
        let kind: LearningEvent.Kind
        var suggested: String? = top?.id
        if row.reopened {
            // after an undo it's a correction, undo already left its negative
            kind = .corrected
            suggested = nil
        } else if row.level == .noIdea {
            kind = .pickedAtNoIdea
            suggested = nil
        } else if destination.id == top?.id {
            kind = viaSendAll && !row.touched ? .sendAllUntouched : .accepted
        } else {
            kind = .corrected
        }
        return LearningEvent(batchId: batch, sparse: features.sparse, dense: features.dense, chosenId: destination.id,
                             suggestedId: suggested, level: row.level, kind: kind)
    }

    // MARK: undo

    private func startUndoTimer() {
        undoTask?.cancel()
        // waits behind the drop zone, the drag ending starts it
        guard !isFileDragging else { return }
        let seconds = timing.undoWindow
        undoTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            self.undoWindowEnded()
        }
    }

    // sent stays sent, files dropped during the send get their own card
    private func undoWindowEnded() {
        // judged against the sent card the user saw, before the tiles take its place
        let watched = pointerIsOverIsland()
        commitSentBatch()
        guard !suggestions.isEmpty else {
            clearCard()
            closeIfUnwatched(pointerWasOver: watched)
            return
        }
        continueWithRemainingRows()
    }

    // the card goes on with the files still on it
    private func continueWithRemainingRows() {
        classifyWaiting()
        sentSummary = nil
        if suggestions.contains(where: { $0.status == .classifying }) {
            cardState = .classifying
        } else {
            cardState = .suggesting
            scheduleParking()
        }
    }

    // send or undo still running, new files wait
    var newRowsWait: Bool {
        switch cardState {
        case .sending, .undoing, .error(_, retry: .undo): return true
        default: return false
        }
    }

    private func isFailed(_ row: FileSuggestion) -> Bool {
        if case .failed = row.status { return true }
        return false
    }

    // a finder drag hides the sent card, undo timer restarts when it's back
    // (a drop on the island ends it instead)
    func fileDragChanged(_ dragging: Bool, urls: [URL] = []) {
        isFileDragging = dragging
        dropZoneChanged(dragging)
        if dragging {
            dragStartedAt = Date()
            // warm vision up while the file is still being dragged
            // ocr only if a dragged file might need it (warm it anyway if there are no urls)
            let ocr = urls.isEmpty || urls.contains { ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "pdf", "webp"].contains($0.pathExtension.lowercased()) }
            let extractor = extractor
            Task {
                await extractor.prewarm(ocr: ocr)
            }
            #if DEBUG
            DebugHooks.preRead(urls)
            #endif
        } else if let started = dragStartedAt {
            // memory left from the pre-warm after a drag that ended elsewhere
            // mouse up comes before the drop, so check if it dropped here when the log is due
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, (self.lastDropAt ?? .distantPast) < started else { return }
                    logMemory("10 s after a drag that wasn't dropped here")
                }
            }
        }
        guard case .sent = cardState else { return }
        if dragging {
            undoTask?.cancel()
            undoTask = nil
        } else {
            startUndoTimer()
        }
    }

    // undo window over, what was sent stays sent
    func commitSentBatch() {
        undoTask?.cancel()
        undoTask = nil
        suggestions.removeAll { $0.isSent }
        batchId = nil
        deletedIds = []
    }

    func undo() {
        let canUndo: Bool
        switch cardState {
        case .sent: canUndo = true
        case .error(_, let retry): canUndo = retry == .resend || retry == .undo
        default: canUndo = false
        }
        guard canUndo, suggestions.contains(where: \.isSent) else { return }
        undoTask?.cancel()
        undoTask = nil
        parkTask?.cancel()
        cardState = .undoing
        let protectedIds = Set(destinationStore.destinations.map(\.id))
        Task {
            var freed = false
            for row in suggestions where row.isSent {
                guard let fileId = row.sentFileId, !deletedIds.contains(fileId) else { continue }
                do {
                    try await driveService.deleteFile(id: fileId, protectedIds: protectedIds)
                    deletedIds.insert(fileId)
                    activity.remove(driveFileIds: [fileId])
                    freed = true
                } catch let error as DriveError where error.category == .notFound {
                    // already gone
                    deletedIds.insert(fileId)
                    activity.remove(driveFileIds: [fileId])
                } catch {
                    let driveError = DriveError.from(error)
                    if driveError.category == .authExpired {
                        authExpired = true
                    }
                    // files deleted before it failed still freed space
                    if freed {
                        storage.refreshSoon()
                    }
                    cardState = .error("Couldn't undo: \(driveError.shortText)", retry: .undo)
                    scheduleParking()
                    classifyWaiting()
                    return
                }
            }
            await classifier.undoLastBatch()
            storage.refreshSoon()
            // back to the chooser with the same suggestions
            for index in suggestions.indices where suggestions[index].isSent {
                suggestions[index].status = .ready
                suggestions[index].reopened = true
            }
            batchId = nil
            deletedIds = []
            sentSummary = nil
            cardState = .suggesting
            scheduleParking()
            classifyWaiting()
        }
    }

    func retry() {
        switch cardState {
        case .error(_, retry: .resend): retrySend()
        case .error(_, retry: .undo): undo()
        default: break
        }
    }

    // MARK: just upload, dismiss

    // old behavior, zip if several, my drive root, no undo or learning
    func justUpload() {
        guard canJustUpload else { return }
        let rows = suggestions.filter { !$0.isSent }
        guard !rows.isEmpty else { return }
        let uploading = Set(rows.map(\.id))
        parkTask?.cancel()
        cardState = .sending
        justUploadProgress = 0
        let generation = cardGeneration
        // the whole job, so the x also stops it while it's zipping
        justUploadTask = Task {
            defer {
                justUploadTask = nil
                justUploadProgress = nil
                justUploadConverting = false
            }
            do {
                // picked formats are honored here too
                var files: [FileItem] = []
                justUploadConverting = rows.contains { $0.convertTo != nil }
                for row in rows {
                    if let format = row.convertTo {
                        files.append(FileItem(url: try await conversion.convert(row.file.url, to: format)))
                    } else {
                        files.append(row.file)
                    }
                }
                justUploadConverting = false
                var item = files[0]
                var zipURL: URL?
                if files.count > 1 || item.isDirectory {
                    let url = try await Self.makeZip(files)
                    zipURL = url
                    item = FileItem(url: url)
                }
                defer {
                    if let zipURL {
                        ZipUtility.cleanupTempFile(at: zipURL)
                    }
                }
                // a zip that finished as the x was clicked
                try Task.checkCancellation()
                let report = Self.progressReporter { [weak self] fraction in
                    guard let self, let current = self.justUploadProgress, fraction > current else { return }
                    self.justUploadProgress = min(1, fraction)
                }
                let file = try await driveService.uploadFile(item, to: nil, progress: report)
                lastUploadedFile = file
                let converted = rows.count == 1 && rows[0].convertTo != nil
                activity.record([ActivityEntry(kind: .justUploaded, name: file.name,
                                               convertedFrom: converted ? rows[0].file.fileExtension.uppercased() : nil,
                                               bytes: file.byteCount ?? item.size,
                                               driveFileId: file.id, webViewLink: file.webViewLink, destinationName: "My Drive")])
                Haptics.sent()
                storage.refreshSoon()
                // files dropped during the upload keep their card
                suggestions.removeAll { uploading.contains($0.id) }
                if suggestions.isEmpty {
                    clearCard()
                    showUploadResult(IslandStatus(kind: .success, message: "Uploaded to My Drive"))
                } else {
                    cardNote = "Uploaded \(files.count) file\(files.count == 1 ? "" : "s") to My Drive"
                    continueWithRemainingRows()
                }
            } catch {
                let driveError = DriveError.from(error)
                // stopped with the card's x the files stay, cleared they're gone
                guard !driveError.isCancelled else {
                    if generation == cardGeneration {
                        continueWithRemainingRows()
                    }
                    return
                }
                if driveError.category == .authExpired {
                    authExpired = true
                }
                cardNote = "Couldn't upload: \(driveError.shortText)"
                continueWithRemainingRows()
            }
        }
    }

    // MARK: save to mac

    var canSaveToMac: Bool {
        cardState == .suggesting && suggestions.contains { $0.convertTo != nil && $0.status == .ready }
    }

    // the rows with a format picked are converted and put next to their originals
    // nothing goes to drive and nothing is learned
    func saveToMac() {
        guard canSaveToMac else { return }
        let rows = suggestions.filter { $0.convertTo != nil && $0.status == .ready }
        parkTask?.cancel()
        cardState = .sending
        savingToMac = true
        saveDone = 0
        for row in rows {
            setStatus(.converting, for: row.id)
        }
        let generation = cardGeneration
        Task {
            var saved: [URL] = []
            var failed: [String] = []
            for row in rows {
                guard generation == cardGeneration, let format = row.convertTo else { break }
                do {
                    let converted = try await conversion.convert(row.file.url, to: format)
                    guard let placed = await SaveToMac.save(converted, nextTo: row.file.url) else {
                        throw ConversionError.failed("not saved")
                    }
                    saved.append(placed)
                    let size = (try? FileManager.default.attributesOfItem(atPath: placed.path)[.size] as? Int64) ?? 0
                    activity.record([ActivityEntry(kind: .savedToMac, name: placed.lastPathComponent,
                                                   convertedFrom: row.file.fileExtension.uppercased(), bytes: size,
                                                   destinationName: placed.deletingLastPathComponent().lastPathComponent,
                                                   localPath: placed.path)])
                    suggestions.removeAll { $0.id == row.id }
                } catch {
                    print("save to mac: \(row.displayName) wasn't saved, \(error.localizedDescription)")
                    failed.append(row.displayName)
                    setStatus(.ready, for: row.id)
                }
                saveDone = Double(saved.count + failed.count) / Double(rows.count)
            }
            savingToMac = false
            guard generation == cardGeneration else { return }
            let summary = "Saved \(saved.count) file\(saved.count == 1 ? "" : "s")"
            if suggestions.isEmpty {
                clearCard()
                showUploadResult(IslandStatus(kind: .success, message: summary, reveal: saved))
            } else {
                let unsaved = failed.isEmpty ? "" : failed[0] + (failed.count > 1 ? " and \(failed.count - 1) more" : "")
                cardNote = failed.isEmpty ? "\(summary) to your Mac"
                    : saved.isEmpty ? "Couldn't save \(unsaved)" : "\(summary), couldn't save \(unsaved)"
                // set after the note, which clears them
                savedFiles = saved
                someNotSaved = !failed.isEmpty
                continueWithRemainingRows()
            }
        }
    }

    // the zip runs detached and blocks, the x is passed on to it
    nonisolated static func makeZip(_ files: [FileItem]) async throws -> URL {
        let job = Task.detached { try ZipUtility.zipFiles(files) }
        return try await withTaskCancellationHandler {
            try await job.value
        } onCancel: {
            job.cancel()
        }
    }

    // the sent card's copy link, a batch goes one link a line
    @discardableResult
    func copySentLinks() -> Bool {
        LinkActions.copy(suggestions.filter(\.isSent).compactMap(\.driveLink))
    }

    func cancelJustUpload() {
        justUploadTask?.cancel()
    }

    // close button, nothing uploaded or learned
    func dismissCard() {
        guard cardState != .sending && cardState != .undoing else { return }
        switch cardState {
        case .sent:
            undoWindowEnded()
        case .error(_, let retry):
            if retry == .undo {
                // undo was asked for, so those files didn't belong there
                let classifier = classifier
                Task { await classifier.undoLastBatch() }
            }
            // sent stays sent, failed rows go, files dropped meanwhile stay
            suggestions.removeAll { $0.isSent || isFailed($0) }
            batchId = nil
            deletedIds = []
            if suggestions.isEmpty {
                clearCard()
            } else {
                continueWithRemainingRows()
            }
        default:
            clearCard()
        }
    }

    func clearCard() {
        // nothing is left to show what's still uploading
        for task in uploadTasks.values {
            task.cancel()
        }
        justUploadTask?.cancel()
        // converted copies were only needed until they went
        conversion.removeTemporaryFiles()
        cardGeneration += 1
        undoTask?.cancel()
        undoTask = nil
        for task in classifyTasks {
            task.cancel()
        }
        classifyTasks = []
        suggestions = []
        featuresById = [:]
        cardNote = nil
        sentSummary = nil
        batchId = nil
        deletedIds = []
        cardState = .idle
    }
}
