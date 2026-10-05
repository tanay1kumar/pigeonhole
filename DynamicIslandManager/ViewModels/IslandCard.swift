import Foundation
import AppKit
import UniformTypeIdentifiers
import os

// the suggestion card (the plan §4.7): drop -> classify -> suggest -> send -> undo, and learning from it.
// stored state lives in IslandViewModel; this is the behavior
extension IslandViewModel {
    static let signposter = OSSignposter(subsystem: "com.dynamicisland.manager", category: .pointsOfInterest)

    var hasDestinations: Bool {
        !destinationStore.destinations.isEmpty
    }

    // rows that still need the user's pick before "send all"
    var unpickedNoIdeaCount: Int {
        suggestions.filter { $0.level == .noIdea && $0.chosen == nil && !$0.isSent }.count
    }

    var canSendAll: Bool {
        cardState == .suggesting && !suggestions.isEmpty
            && !suggestions.contains { $0.status == .classifying || $0.status == .waiting }
            && unpickedNoIdeaCount == 0
    }

    // MARK: drops

    // called synchronously from .onDrop: the card shows "classifying" before any file has loaded
    func handleDrop(_ providers: [NSItemProvider]) {
        guard !providers.isEmpty else { return }
        let started = DispatchTime.now()
        let signpost = Self.signposter.beginInterval("dropToRank", id: Self.signposter.makeSignpostID())

        // no destinations yet: the old cube grid takes the files
        guard hasDestinations else {
            Self.signposter.endInterval("dropToRank", signpost)
            loadForGrid(providers)
            return
        }

        switch cardState {
        case .idle:
            cardState = .classifying
        case .sent:
            // a new drop ends the undo window and starts a new card
            commitSentBatch()
            cardState = .classifying
        case .error(_, retry: .undo):
            // an undo isn't finished: new files wait until it's retried or dismissed
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

        let generation = cardGeneration
        Task {
            let loaded = await Self.loadFiles(providers)
            // ✕ before the files finished loading: they went with the card
            guard generation == cardGeneration else {
                Self.signposter.endInterval("dropToRank", signpost)
                return
            }
            addRows(loaded.items, failures: loaded.failures, drop: (started, signpost))
        }
    }

    // providers load in parallel; results keep the drop order
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

    // the old flow: files queue up for the cube grid
    private func loadForGrid(_ providers: [NSItemProvider]) {
        Task {
            let loaded = await Self.loadFiles(providers)
            addFiles(loaded.items)
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
            let results = await extractor.extract(rows.map(\.file.url))
            // ✕ while classifying: nobody wants these anymore
            guard !Task.isCancelled else { return }
            for (row, features) in zip(rows, results) {
                guard suggestions.contains(where: { $0.id == row.id }) else { continue }
                featuresById[row.id] = features
                // read now: the list may have changed while the files were read
                let ranking = await classifier.rank(features, among: destinationStore.destinations)
                apply(ranking, to: row.id)
            }
            finishClassifying(drop: drop)
        }
        classifyTasks.append(task)
    }

    private func apply(_ ranking: Ranking, to id: UUID) {
        guard let index = suggestions.firstIndex(where: { $0.id == id }), !isInFlight(suggestions[index]) else { return }
        // a folder removed while this file was being ranked doesn't stay on its list
        let current = Set(destinationStore.destinations.map(\.id))
        let items = ranking.items.filter { current.contains($0.destination.id) }
        let level = items.isEmpty ? .noIdea : ranking.level
        suggestions[index].ranked = items
        suggestions[index].level = level
        suggestions[index].why = ranking.why
        if !suggestions[index].touched {
            // no idea: the user picks; otherwise the top suggestion is preselected
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
            print(String(format: "dropToRank: %.1f ms (%d file%@)", ms, suggestions.count, suggestions.count == 1 ? "" : "s"))
        }
    }

    // destinations changed under an open card: rank again, never keep a removed folder
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
        guard !destinations.isEmpty else {
            // nowhere left to send: back to the grid with the files (a send in progress finishes first)
            guard cardState != .sending && cardState != .undoing else { return }
            let files = suggestions.filter { !$0.isSent }.map(\.file)
            if case .sent = cardState {
                commitSentBatch()
            }
            clearCard()
            addFiles(files)
            return
        }
        // a removed choice falls back to the next ranked folder (apply picks the top again)
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
        }
    }

    private func isInFlight(_ row: FileSuggestion) -> Bool {
        row.status == .sending || row.isSent
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

    // one row (single-file card: Send, or picking a chip sends it)
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
        guard case .error(_, retry: .resend) = cardState else { return }
        let failed = suggestions.filter {
            if case .failed = $0.status { return true }
            return false
        }.map(\.id)
        startSend(failed, viaSendAll: lastSendWasSendAll)
    }

    private func startSend(_ ids: [UUID], viaSendAll: Bool) {
        // where each row goes is fixed now, edits in the setup window can't change a send halfway
        let plan = ids.compactMap { id -> (UUID, Destination)? in
            guard let row = suggestions.first(where: { $0.id == id }), !row.isSent, let destination = row.chosen else { return nil }
            return (id, destination)
        }
        guard !plan.isEmpty else { return }
        parkTask?.cancel()
        undoTask?.cancel()
        for (id, _) in plan {
            if let index = suggestions.firstIndex(where: { $0.id == id }) {
                suggestions[index].status = .sending
            }
        }
        cardState = .sending
        lastSendWasSendAll = viaSendAll
        let batch = batchId ?? UUID()
        batchId = batch
        Task {
            var events: [LearningEvent] = []
            var failures: [String] = []
            for (id, destination) in plan {
                guard let row = suggestions.first(where: { $0.id == id }) else { continue }
                do {
                    let file = try await upload(row, to: destination)
                    if let current = suggestions.firstIndex(where: { $0.id == id }) {
                        suggestions[current].status = .sent(fileId: file.id)
                    }
                    if let event = learningEvent(for: row, sentTo: destination, batch: batch, viaSendAll: viaSendAll) {
                        events.append(event)
                    }
                } catch {
                    let driveError = DriveError.from(error)
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
            sendFinished(batch: batch, failures: failures)
        }
    }

    private func sendFinished(batch: UUID, failures: [String]) {
        if failures.isEmpty {
            let sent = suggestions.filter(\.isSent)
            if sent.count == 1, let destination = sent.first?.chosen {
                sentSummary = "Sent to \(destination.name)"
            } else {
                sentSummary = "Sent \(sent.count) files"
            }
            cardState = .sent(batchId: batch)
            startUndoTimer()
        } else {
            let first = failures[0]
            let text = failures.count == 1 ? first : "\(failures.count) files didn't send: \(first)"
            cardState = .error(text, retry: .resend)
            scheduleParking()
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

    private func upload(_ row: FileSuggestion, to destination: Destination) async throws -> DriveFile {
        guard row.file.isDirectory else {
            return try await driveService.uploadFile(row.file, to: destination.id)
        }
        // folders go up as <name>.zip, zipped off main
        let file = row.file
        let zipURL = try await Task.detached { try ZipUtility.zipFiles([file]) }.value
        defer { ZipUtility.cleanupTempFile(at: zipURL) }
        return try await driveService.uploadFile(FileItem(url: zipURL), to: destination.id)
    }

    // the plan §4.6 table
    func learningEvent(for row: FileSuggestion, sentTo destination: Destination, batch: UUID, viaSendAll: Bool) -> LearningEvent? {
        guard let features = featuresById[row.id] else { return nil }
        let top = row.top
        let kind: LearningEvent.Kind
        var suggested: String? = top?.id
        if row.reopened {
            // after an undo: a correction, and the undo already left its negative
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
        // behind the drop zone it waits; the drag's end starts it
        guard !isFileDragging else { return }
        let seconds = timing.undoWindow
        undoTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            self.undoWindowEnded()
        }
    }

    // what was sent stays sent; files dropped during the send get their own card
    private func undoWindowEnded() {
        commitSentBatch()
        guard !suggestions.isEmpty else {
            clearCard()
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

    // a send or undo isn't finished: files dropped now wait
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

    // a finder drag hides a sent card behind the drop zone: its undo window waits, and starts
    // again when the card comes back (a drop on the island ends it instead)
    func fileDragChanged(_ dragging: Bool) {
        isFileDragging = dragging
        guard case .sent = cardState else { return }
        if dragging {
            undoTask?.cancel()
            undoTask = nil
        } else {
            startUndoTimer()
        }
    }

    // the undo window is over: what was sent stays sent
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
            for row in suggestions where row.isSent {
                guard let fileId = row.sentFileId, !deletedIds.contains(fileId) else { continue }
                do {
                    try await driveService.deleteFile(id: fileId, protectedIds: protectedIds)
                    deletedIds.insert(fileId)
                } catch let error as DriveError where error.category == .notFound {
                    // already gone
                    deletedIds.insert(fileId)
                } catch {
                    let driveError = DriveError.from(error)
                    if driveError.category == .authExpired {
                        authExpired = true
                    }
                    cardState = .error("Couldn't undo: \(driveError.shortText)", retry: .undo)
                    scheduleParking()
                    classifyWaiting()
                    return
                }
            }
            await classifier.undoLastBatch()
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

    // old behavior: zip if several, my drive root, no undo, no learning
    func justUpload() {
        guard cardState == .suggesting else { return }
        let rows = suggestions.filter { !$0.isSent }
        let files = rows.map(\.file)
        guard !files.isEmpty else { return }
        let uploading = Set(rows.map(\.id))
        parkTask?.cancel()
        cardState = .sending
        Task {
            do {
                var item = files[0]
                var zipURL: URL?
                if files.count > 1 || item.isDirectory {
                    let url = try await Task.detached { try ZipUtility.zipFiles(files) }.value
                    zipURL = url
                    item = FileItem(url: url)
                }
                defer {
                    if let zipURL {
                        ZipUtility.cleanupTempFile(at: zipURL)
                    }
                }
                lastUploadedFile = try await driveService.uploadFile(item, to: nil)
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
                if driveError.category == .authExpired {
                    authExpired = true
                }
                cardNote = "Couldn't upload: \(driveError.shortText)"
                continueWithRemainingRows()
            }
        }
    }

    // ✕: nothing uploaded, nothing learned
    func dismissCard() {
        guard cardState != .sending && cardState != .undoing else { return }
        switch cardState {
        case .sent:
            undoWindowEnded()
        case .error(_, let retry):
            if retry == .undo {
                // the undo was asked for: those files didn't belong there, even if one is still in drive
                let classifier = classifier
                Task { await classifier.undoLastBatch() }
            }
            // what was sent stays sent; the failed rows go; files dropped meanwhile stay
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
