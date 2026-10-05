import Foundation
import NaturalLanguage

// what one user action teaches the classifier (the plan §4.6)
struct LearningEvent {
    enum Kind: String {
        case accepted            // sent to the top suggestion
        case corrected           // sent somewhere else (or picked again after an undo)
        case pickedAtNoIdea      // the user chose at "no idea"
        case sendAllUntouched    // "send all" on a row nobody changed
    }

    let batchId: UUID
    let sparse: SparseVector
    let dense: [Float]?
    let chosenId: String
    let suggestedId: String?     // the top-1 shown; nil at "no idea" and for rows reopened by undo
    let level: Level
    let kind: Kind

    var weight: Float {
        switch kind {
        case .accepted, .pickedAtNoIdea: return 1
        case .corrected: return 2
        case .sendAllUntouched: return level == .confident ? 1 : 0.5
        }
    }
}

// learned examples per destination, kept on disk as hashed feature indices and 12-bit weights.
// no text, names or paths, but hashed words can be recovered with a dictionary, so it stays local.
// a class, not an actor: everything goes through one serial queue and every method is synchronous
final class LearningStore {
    static let fileVersion = 1
    static let visionRevision = 2
    static let maxExamples = 100
    static let maxNegatives = 50
    static let storedFeatures = 100
    static let negativeValue: Float = 0.5

    static var currentEmbeddingRevision: Int {
        NLEmbedding.currentSentenceEmbeddingRevision(for: .english)
    }

    // the real file; cli modes never touch it
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DynamicIslandManager", isDirectory: true)
            .appendingPathComponent("learning.json")
    }

    // a learned vector exactly as saved (top 100 features, 12-bit weights) plus its unit-length decode.
    // saving writes the bytes back untouched, so a relaunch gets the very same vector
    struct StoredVector: Equatable {
        let code: Data
        let vector: SparseVector

        init(_ vector: SparseVector) {
            self.init(code: LearningStore.encode(vector))
        }

        init(code: Data) {
            self.code = code
            self.vector = LearningStore.decode(code)
        }
    }

    struct Example: Equatable {
        var stored: StoredVector
        var weight: Float
        var time: Int
        var id = UUID()              // in memory only, for undo

        var vector: SparseVector { stored.vector }
    }

    struct Negative: Equatable {
        var stored: StoredVector
        var value: Float
        var time: Int
        var id = UUID()
        var fromUndo = false         // in memory only

        var vector: SparseVector { stored.vector }
    }

    struct Stats: Codable, Equatable {
        var accepted = 0
        var corrected = 0
        var undone = 0
    }

    struct DestinationData: Equatable {
        var examples: [Example] = []
        var negatives: [Negative] = []
        var denseSum: [Float]?
        var denseWeight: Float = 0
        var stats = Stats()
    }

    // what the last batch changed, so undo can take it back
    private struct BatchRecord {
        struct Entry {
            let destinationId: String
            let exampleId: UUID
            let weight: Float
            let dense: [Float]?
            var negative: (destinationId: String, id: UUID)?
            let kind: LearningEvent.Kind
            // what the caps pushed out to make room, so undo can put it back
            var evictedExamples: [Example] = []
            var evictedNegatives: [Negative] = []
            // its folder was removed meanwhile: undo leaves that id alone
            var destinationGone = false
        }
        let batchId: UUID
        var entries: [Entry] = []
        var sent: [(destinationId: String, vector: SparseVector)] = []
    }

    let fileURL: URL?
    var writeDelay: Double = 1
    private let queue = DispatchQueue(label: "com.dynamicisland.manager.learning")
    private var destinations: [String: DestinationData] = [:]
    private var lastBatch: BatchRecord?
    private var pendingWrite: DispatchWorkItem?
    private let embeddingRevision: Int
    private(set) var loadNote = "new"     // what happened when the file was read (tests, logs)

    // nil means in memory only (eval, tests)
    init(fileURL: URL?, embeddingRevision: Int = LearningStore.currentEmbeddingRevision) {
        self.fileURL = fileURL
        self.embeddingRevision = embeddingRevision
        if let fileURL {
            load(from: fileURL)
        }
    }

    // MARK: reading

    func snapshot() -> [String: DestinationData] {
        queue.sync { destinations }
    }

    func data(for id: String) -> DestinationData? {
        queue.sync { destinations[id] }
    }

    var canUndo: Bool {
        queue.sync { lastBatch != nil }
    }

    // MARK: learning

    func record(_ events: [LearningEvent]) {
        guard !events.isEmpty else { return }
        queue.sync {
            let now = Int(Date().timeIntervalSince1970)
            for event in events {
                // sends that retry a batch (same id) join it, so one undo covers everything
                if lastBatch?.batchId != event.batchId {
                    lastBatch = BatchRecord(batchId: event.batchId)
                }
                let stored = StoredVector(event.sparse)
                var target = destinations[event.chosenId] ?? DestinationData()

                // a row reopened by undo went back to the same folder: that undo negative was wrong
                if let index = target.negatives.firstIndex(where: { $0.fromUndo && $0.stored == stored }) {
                    target.negatives.remove(at: index)
                }

                let example = Example(stored: stored, weight: event.weight, time: now)
                target.examples.append(example)
                var evictedExamples: [Example] = []
                if target.examples.count > Self.maxExamples {
                    let overflow = target.examples.count - Self.maxExamples
                    evictedExamples = Array(target.examples.prefix(overflow))
                    target.examples.removeFirst(overflow)
                }
                if let dense = event.dense, dense.count == (target.denseSum?.count ?? dense.count) {
                    target.denseSum = Self.add(target.denseSum ?? [Float](repeating: 0, count: dense.count), dense, scale: event.weight)
                    target.denseWeight += event.weight
                }
                if event.kind == .corrected {
                    target.stats.corrected += 1
                } else {
                    target.stats.accepted += 1
                }
                destinations[event.chosenId] = target

                // the suggestion it overrode learns a little that it was wrong
                var negativeRecord: (String, UUID)?
                var evictedNegatives: [Negative] = []
                if event.kind == .corrected, let wrong = event.suggestedId, wrong != event.chosenId {
                    let negative = Negative(stored: stored, value: Self.negativeValue, time: now)
                    var other = destinations[wrong] ?? DestinationData()
                    other.negatives.append(negative)
                    if other.negatives.count > Self.maxNegatives {
                        let overflow = other.negatives.count - Self.maxNegatives
                        evictedNegatives = Array(other.negatives.prefix(overflow))
                        other.negatives.removeFirst(overflow)
                    }
                    destinations[wrong] = other
                    negativeRecord = (wrong, negative.id)
                }

                lastBatch?.entries.append(BatchRecord.Entry(destinationId: event.chosenId, exampleId: example.id,
                                                            weight: event.weight, dense: event.dense,
                                                            negative: negativeRecord, kind: event.kind,
                                                            evictedExamples: evictedExamples,
                                                            evictedNegatives: evictedNegatives))
                lastBatch?.sent.append((event.chosenId, event.sparse))
            }
            scheduleWrite()
        }
    }

    // takes the last batch back, then remembers each file didn't belong where it went
    @discardableResult
    func undoLastBatch() -> Bool {
        queue.sync {
            guard let batch = lastBatch else { return false }
            let now = Int(Date().timeIntervalSince1970)
            // newest first, so what each entry pushed out at the caps goes back in its old place
            for entry in batch.entries.reversed() {
                if !entry.destinationGone, var target = destinations[entry.destinationId] {
                    if let index = target.examples.firstIndex(where: { $0.id == entry.exampleId }) {
                        target.examples.remove(at: index)
                    }
                    target.examples.insert(contentsOf: entry.evictedExamples, at: 0)
                    if let dense = entry.dense, let sum = target.denseSum, sum.count == dense.count {
                        target.denseSum = Self.add(sum, dense, scale: -entry.weight)
                        target.denseWeight = max(0, target.denseWeight - entry.weight)
                        if target.denseWeight < 1e-6 {
                            target.denseSum = nil
                            target.denseWeight = 0
                        }
                    }
                    if entry.kind == .corrected {
                        target.stats.corrected = max(0, target.stats.corrected - 1)
                    } else {
                        target.stats.accepted = max(0, target.stats.accepted - 1)
                    }
                    target.stats.undone += 1
                    destinations[entry.destinationId] = target
                }
                if let negative = entry.negative, var other = destinations[negative.destinationId] {
                    other.negatives.removeAll { $0.id == negative.id }
                    other.negatives.insert(contentsOf: entry.evictedNegatives, at: 0)
                    destinations[negative.destinationId] = other
                }
            }
            for sent in batch.sent {
                var target = destinations[sent.destinationId] ?? DestinationData()
                target.negatives.append(Negative(stored: StoredVector(sent.vector), value: Self.negativeValue,
                                                 time: now, fromUndo: true))
                if target.negatives.count > Self.maxNegatives {
                    target.negatives.removeFirst(target.negatives.count - Self.maxNegatives)
                }
                destinations[sent.destinationId] = target
            }
            lastBatch = nil
            scheduleWrite()
            return true
        }
    }

    // a destination was removed. the pending undo forgets only that folder: the rest of the batch
    // can still be undone, and a retry with the same batch id still joins it
    func removeData(for id: String) {
        queue.sync {
            pendingWrite?.cancel()
            pendingWrite = nil
            destinations[id] = nil
            if var batch = lastBatch {
                batch.sent.removeAll { $0.destinationId == id }
                for index in batch.entries.indices {
                    if batch.entries[index].destinationId == id {
                        batch.entries[index].destinationGone = true
                    }
                    if batch.entries[index].negative?.destinationId == id {
                        batch.entries[index].negative = nil
                        batch.entries[index].evictedNegatives = []
                    }
                }
                lastBatch = batch
            }
            writeNow()
        }
    }

    // drops everything that was learned, file included
    func reset() {
        queue.sync {
            pendingWrite?.cancel()
            pendingWrite = nil
            destinations.removeAll()
            lastBatch = nil
            if let fileURL {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    // keeps only the destinations that still exist
    func prune(keeping ids: Set<String>) {
        queue.sync {
            let stale = destinations.keys.filter { !ids.contains($0) }
            guard !stale.isEmpty else { return }
            for id in stale {
                destinations[id] = nil
            }
            scheduleWrite()
        }
    }

    // synchronous write, for quitting and before every cli exit
    func flush() {
        queue.sync {
            guard pendingWrite != nil else { return }
            pendingWrite?.cancel()
            pendingWrite = nil
            writeNow()
        }
    }

    // MARK: vectors

    // what a vector looks like once stored: the top 100 features, 12-bit weights, back to unit length
    static func storedForm(_ vector: SparseVector) -> SparseVector {
        decode(encode(vector))
    }

    static func encode(_ vector: SparseVector) -> Data {
        let top = zip(vector.indices, vector.values)
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            .prefix(storedFeatures)
            .sorted { $0.0 < $1.0 }
        var data = Data(capacity: top.count * 4)
        for (index, value) in top {
            let quantized = UInt32((min(max(value, 0), 1) * 4095).rounded())
            var word = ((index & 0xFFFFF) << 12 | quantized).littleEndian
            withUnsafeBytes(of: &word) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func decode(_ data: Data) -> SparseVector {
        var pairs: [(UInt32, Float)] = []
        pairs.reserveCapacity(data.count / 4)
        var offset = 0
        while offset + 4 <= data.count {
            let word = data[data.startIndex + offset..<data.startIndex + offset + 4].withUnsafeBytes {
                UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
            }
            let value = Float(word & 0xFFF) / 4095
            if value > 0 {
                pairs.append((word >> 12, value))
            }
            offset += 4
        }
        return SparseVector(pairs: pairs).normalized()
    }

    private static func add(_ a: [Float], _ b: [Float], scale: Float) -> [Float] {
        var result = a
        for index in result.indices where index < b.count {
            result[index] += b[index] * scale
        }
        return result
    }

    // MARK: file

    private struct FileFormat: Codable {
        struct StoredExample: Codable {
            var w: Float
            var t: Int
            var f: String
        }

        struct StoredNegative: Codable {
            var v: Float
            var t: Int
            var f: String
        }

        struct StoredDestination: Codable {
            var examples: [StoredExample]
            var negatives: [StoredNegative]
            var denseSum: [Float]?
            var denseWeight: Float
            var stats: Stats
        }

        var version: Int
        var featureVersion: Int
        var visionRevision: Int
        var embeddingRevision: Int
        var destinations: [String: StoredDestination]
    }

    private func load(from url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        guard let header = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              header["version"] as? Int == Self.fileVersion,
              let file = try? JSONDecoder().decode(FileFormat.self, from: data) else {
            // unknown version or unreadable: start over
            loadNote = "discarded unreadable or unknown-version file"
            print("learning: \(loadNote)")
            return
        }
        let vectorsValid = file.featureVersion == FeatureVectorizer.featureVersion && file.visionRevision == Self.visionRevision
        let denseValid = vectorsValid && file.embeddingRevision == embeddingRevision
        for (id, stored) in file.destinations {
            var destination = DestinationData()
            destination.stats = stored.stats
            if vectorsValid {
                destination.examples = stored.examples.compactMap { example in
                    Data(base64Encoded: example.f).map { Example(stored: StoredVector(code: $0), weight: example.w, time: example.t) }
                }
                destination.negatives = stored.negatives.compactMap { negative in
                    Data(base64Encoded: negative.f).map { Negative(stored: StoredVector(code: $0), value: negative.v, time: negative.t) }
                }
            }
            if denseValid {
                destination.denseSum = stored.denseSum
                destination.denseWeight = stored.denseSum == nil ? 0 : stored.denseWeight
            }
            destinations[id] = destination
        }
        if !vectorsValid {
            loadNote = "dropped learned vectors (feature version or vision revision changed)"
        } else if !denseValid {
            loadNote = "dropped dense sums (embedding revision changed)"
        } else {
            loadNote = "loaded"
        }
        if loadNote != "loaded" {
            print("learning: \(loadNote)")
        }
    }

    private func scheduleWrite() {
        guard fileURL != nil else { return }
        pendingWrite?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingWrite = nil
            self?.writeNow()
        }
        pendingWrite = work
        queue.asyncAfter(deadline: .now() + writeDelay, execute: work)
    }

    // on the queue
    private func writeNow() {
        guard let fileURL, let data = try? encodedFile() else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            // only this user can read it
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            print("learning: couldn't save: \(error.localizedDescription)")
        }
    }

    private func encodedFile() throws -> Data {
        var stored: [String: FileFormat.StoredDestination] = [:]
        for (id, destination) in destinations {
            stored[id] = FileFormat.StoredDestination(
                examples: destination.examples.map { .init(w: $0.weight, t: $0.time, f: $0.stored.code.base64EncodedString()) },
                negatives: destination.negatives.map { .init(v: $0.value, t: $0.time, f: $0.stored.code.base64EncodedString()) },
                denseSum: destination.denseSum,
                denseWeight: destination.denseWeight,
                stats: destination.stats)
        }
        let file = FileFormat(version: Self.fileVersion, featureVersion: FeatureVectorizer.featureVersion,
                              visionRevision: Self.visionRevision, embeddingRevision: embeddingRevision,
                              destinations: stored)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(file)
    }

    #if DEBUG
    // fills every destination to the caps, for the size check
    func fillToCaps(destinationIds: [String], featuresPerVector: Int = 100, denseSize: Int = 512) {
        queue.sync {
            let now = Int(Date().timeIntervalSince1970)
            var seed: UInt32 = 1
            func randomVector() -> SparseVector {
                var pairs: [(UInt32, Float)] = []
                for _ in 0..<featuresPerVector {
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    pairs.append((seed >> 12, Float(seed & 0xFFF + 1) / 4096))
                }
                return SparseVector(pairs: pairs).normalized()
            }
            for id in destinationIds {
                var destination = DestinationData()
                destination.examples = (0..<Self.maxExamples).map { _ in Example(stored: StoredVector(randomVector()), weight: 1, time: now) }
                destination.negatives = (0..<Self.maxNegatives).map { _ in Negative(stored: StoredVector(randomVector()), value: 0.5, time: now) }
                destination.denseSum = (0..<denseSize).map { Float($0 % 97) / 97 - 0.5 + 0.000123 }
                destination.denseWeight = 100
                destination.stats = Stats(accepted: 100, corrected: 20, undone: 3)
                destinations[id] = destination
            }
            writeNow()
        }
    }
    #endif
}
