import Foundation
import AppKit
import Vision
import ImageIO
import PDFKit
import NaturalLanguage
import UniformTypeIdentifiers
import CoreServices
import os

// extraction options, the app uses the defaults
struct ExtractOptions: Hashable {
    var deadline: Double = 2            // seconds per file, then keep what's there
    var diagBoxes = false               // --diag-boxes, count text boxes at 1600 px for every image
    var origin: String?                 // eval gives every file from:<origin>
}

// set when nobody wants the result anymore, checked between stages
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isCancelled: Bool {
        lock.withLock { value }
    }

    func cancel() {
        lock.withLock { value = true }
    }
}

// latest features so far, a deadline hands back whatever is here
final class SnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: FileFeatures?

    func store(_ features: FileFeatures) {
        lock.withLock { latest = features }
    }

    func load() -> FileFeatures? {
        lock.withLock { latest }
    }
}

// resumes the continuation once, work or deadline, whichever is first
private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        let pending: CheckedContinuation<T, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}

// turns dropped files into FileFeatures, max 2 files at once, off main
// 2 s per file (then whatever it has), cached by path + size + mtime
actor FeatureExtractor {
    static let signposter = OSSignposter(subsystem: "com.dynamicisland.manager", category: .pointsOfInterest)
    static let maxParallel = 2
    static let cacheSize = 50
    // concurrent so a stuck file can't block the next, slots cap it at 2
    static let workQueue = DispatchQueue(label: "com.dynamicisland.manager.extract", qos: .userInitiated, attributes: .concurrent)

    private struct CacheKey: Hashable {
        let path: String
        let size: Int64
        let modified: Double
        let options: ExtractOptions
    }

    // one extraction several callers can wait on, stops once they all give up
    private final class Shared: @unchecked Sendable {
        let task: Task<FileFeatures, Never>
        let cancel: CancelFlag
        var waiters = 0

        init(task: Task<FileFeatures, Never>, cancel: CancelFlag) {
            self.task = task
            self.cancel = cancel
        }
    }

    private var cache: [CacheKey: FileFeatures] = [:]
    private var cacheOrder: [CacheKey] = []           // oldest first
    private var inFlight: [CacheKey: Shared] = [:]
    private var sentenceEmbedding: NLEmbedding?
    private var wordEmbedding: NLEmbedding?
    private var triedEmbedding = false
    private var triedWordEmbedding = false

    // at most maxParallel files at once, the rest wait in order
    private var running = 0
    private var slotWaiters: [CheckedContinuation<Void, Never>] = []

    private(set) var extractions = 0                  // real extractions, cache hits excluded (tests)
    private(set) var maxRunning = 0                   // most files extracted at once (tests)

    // MARK: api

    // features for each url in order, a cancelled caller gets empty ones for the rest
    func extract(_ urls: [URL], options: ExtractOptions = ExtractOptions(), useCache: Bool = true) async -> [FileFeatures] {
        var results = [FileFeatures?](repeating: nil, count: urls.count)
        await withTaskGroup(of: (Int, FileFeatures).self) { group in
            var next = 0
            func addNext() {
                // the group doesn't see the parent's cancellation, check the task itself
                guard next < urls.count, !Task.isCancelled else { return }
                let index = next
                let url = urls[index]
                next += 1
                group.addTask {
                    (index, await self.features(for: url, options: options, useCache: useCache))
                }
            }
            // slots do the real limiting, this just keeps the queue short
            for _ in 0..<min(Self.maxParallel, urls.count) {
                addNext()
            }
            while let (index, features) = await group.next() {
                results[index] = features
                addNext()
            }
        }
        return results.map { $0 ?? Self.cancelledFeatures() }
    }

    // vision unloads after a few idle seconds, so warm it on every finder drag
    // ocr too if a dragged file might need it, and the heic decoder (also goes cold)
    func prewarm(ocr: Bool = false) async {
        let started = DispatchTime.now()
        await withCheckedContinuation { continuation in
            Self.workQueue.async {
                Self.tinyClassify()
                Self.tinyHEICDecode()
                if ocr {
                    Self.tinyOCR()
                }
                continuation.resume()
            }
        }
        _ = loadEmbedding()
        print(String(format: "prewarm: %.1f ms%@", Self.ms(since: started), ocr ? " (with ocr)" : ""))
    }

    func clearCache() {
        cache.removeAll()
        cacheOrder.removeAll()
    }

    var cacheCount: Int { cache.count }

    // MARK: cache and in-flight

    private func features(for url: URL, options: ExtractOptions, useCache: Bool) async -> FileFeatures {
        guard !Task.isCancelled else { return Self.cancelledFeatures() }
        let resolved = url.resolvingSymlinksInPath()
        guard useCache, let key = cacheKey(for: resolved, options: options) else {
            let flag = CancelFlag()
            return await withTaskCancellationHandler {
                await run(resolved, options: options, cancel: flag)
            } onCancel: {
                flag.cancel()
            }
        }
        if let hit = cache[key] {
            touch(key)
            var features = hit
            features.timings = ["total": 0, "cache": 1]
            return features
        }

        let shared: Shared
        if let existing = inFlight[key], !existing.cancel.isCancelled {
            shared = existing
        } else {
            // nothing running, or everyone waiting gave up, start fresh
            let flag = CancelFlag()
            shared = Shared(task: Task { await self.run(resolved, options: options, cancel: flag) }, cancel: flag)
            inFlight[key] = shared
        }
        shared.waiters += 1
        let features = await withTaskCancellationHandler {
            await shared.task.value
        } onCancel: {
            Task { await self.leave(shared) }
        }
        if inFlight[key] === shared {
            inFlight[key] = nil
            store(features, for: key)
        }
        return features
    }

    // a waiter gave up, the last one stops the work
    private func leave(_ shared: Shared) {
        shared.waiters -= 1
        if shared.waiters <= 0 {
            shared.cancel.cancel()
        }
    }

    private func acquireSlot() async {
        if running < Self.maxParallel {
            running += 1
        } else {
            // a finishing run hands its slot straight over
            await withCheckedContinuation { slotWaiters.append($0) }
        }
        maxRunning = max(maxRunning, running)
    }

    private func releaseSlot() {
        if slotWaiters.isEmpty {
            running -= 1
        } else {
            slotWaiters.removeFirst().resume()
        }
    }

    private func run(_ url: URL, options: ExtractOptions, cancel: CancelFlag) async -> FileFeatures {
        await acquireSlot()
        defer { releaseSlot() }
        guard !cancel.isCancelled else { return Self.cancelledFeatures() }
        extractions += 1

        // this blocks its thread so it runs on gcd, not swift's thread pool
        // a stuck read (icloud download, slow share) would starve other async work
        // a timer races it and hands back what's there so far
        let box = SnapshotBox()
        var features: FileFeatures = await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            Self.workQueue.async {
                once.resume(Self.extractOne(url, options: options, snapshot: box, cancel: cancel))
            }
            Self.workQueue.asyncAfter(deadline: .now() + options.deadline + 0.05) {
                var partial = box.load() ?? FileFeatures()
                partial.deadlineHit = true
                once.resume(partial)
            }
        }

        // the embedding stays on the actor (concurrent use of one NLEmbedding crashes)
        if !features.summary.isEmpty && !features.deadlineHit && !features.cancelled && isEnglish(features.languageSample) {
            let started = DispatchTime.now()
            features.dense = embed(features.summary)
            features.timings["embed"] = Self.ms(since: started)
            features.timings["total", default: 0] += features.timings["embed"] ?? 0
        }
        if cancel.isCancelled {
            features.cancelled = true
        }
        return features
    }

    private func cacheKey(for url: URL, options: ExtractOptions) -> CacheKey? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
        return CacheKey(path: url.path,
                        size: Int64(values.fileSize ?? -1),
                        modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
                        options: options)
    }

    private func touch(_ key: CacheKey) {
        if let index = cacheOrder.firstIndex(of: key) {
            cacheOrder.remove(at: index)
        }
        cacheOrder.append(key)
    }

    private func store(_ features: FileFeatures, for key: CacheKey) {
        // cut short, cancelled or unreadable, try again next time
        guard !features.deadlineHit, !features.cancelled, features.error == nil else { return }
        cache[key] = features
        touch(key)
        while cacheOrder.count > Self.cacheSize {
            cache[cacheOrder.removeFirst()] = nil
        }
    }

    static func cancelledFeatures() -> FileFeatures {
        var features = FileFeatures()
        features.cancelled = true
        return features
    }

    // MARK: embedding

    private func loadEmbedding() -> NLEmbedding? {
        if !triedEmbedding {
            triedEmbedding = true
            sentenceEmbedding = NLEmbedding.sentenceEmbedding(for: .english)
        }
        return sentenceEmbedding
    }

    private func loadWordEmbedding() -> NLEmbedding? {
        if !triedWordEmbedding {
            triedWordEmbedding = true
            wordEmbedding = NLEmbedding.wordEmbedding(for: .english)
        }
        return wordEmbedding
    }

    func embed(_ text: String) -> [Float]? {
        guard let embedding = loadEmbedding(), let vector = embedding.vector(for: text) else { return nil }
        var squares: Double = 0
        for value in vector {
            squares += value * value
        }
        let length = squares.squareRoot()
        guard length > 0 else { return nil }
        // raw norms are about 8-9
        return vector.map { Float($0 / length) }
    }

    // embedding is english only, but all caps receipts get detected as dutch
    // so count english words before trusting a "not english"
    func isEnglish(_ sample: String) -> Bool {
        guard sample.count > 40 else { return true }
        if NLLanguageRecognizer.dominantLanguage(for: sample) == .english {
            return true
        }
        let words = sample.split(whereSeparator: { !$0.isLetter }).map { $0.lowercased() }.filter { $0.count >= 3 }
        guard !words.isEmpty, let vocabulary = loadWordEmbedding() else { return words.isEmpty }
        let sampled = words.prefix(60)
        let known = sampled.filter { vocabulary.contains($0) }.count
        return Double(known) / Double(sampled.count) >= 0.5
    }

    // MARK: one file (sync, never on main)

    nonisolated static func extractOne(_ url: URL, options: ExtractOptions,
                                       snapshot: SnapshotBox = SnapshotBox(), cancel: CancelFlag = CancelFlag()) -> FileFeatures {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let started = DispatchTime.now()
        let signpostID = signposter.makeSignpostID()
        let interval = signposter.beginInterval("extract", id: signpostID)
        defer { signposter.endInterval("extract", interval) }

        var context = ExtractionContext(url: url, options: options, started: started, snapshot: snapshot, cancel: cancel)
        autoreleasepool {
            context.run()
        }
        var features = context.finish()
        // diagnostics run outside the budgets
        features.timings["total"] = ms(since: started) - context.diagnosticMs
        return features
    }

    nonisolated static func ms(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    // a 64x64 classify wakes vision's model up
    nonisolated static func tinyClassify() {
        guard let image = tinyImage() else { return }
        let request = VNClassifyImageRequest()
        request.revision = VNClassifyImageRequestRevision2
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    }

    nonisolated static func tinyOCR() {
        guard let image = tinyImage() else { return }
        let request = VNRecognizeTextRequest()
        request.revision = VNRecognizeTextRequestRevision3
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    }

    // tiny heic made once in memory, decoding it wakes the heic decoder
    static let tinyHEIC: Data? = {
        guard let image = tinyImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }()

    nonisolated static func tinyHEICDecode() {
        guard let data = tinyHEIC, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 64]
        _ = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // opaque, imageio complains about an unused alpha channel
    nonisolated static func tinyImage() -> CGImage? {
        guard let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0.4, green: 0.6, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return context.makeImage()
    }
}

// MARK: the work for one file

private struct ExtractionContext {
    let url: URL
    let options: ExtractOptions
    let started: DispatchTime
    let snapshot: SnapshotBox
    let cancel: CancelFlag
    var diagnosticMs: Double = 0         // --diag-boxes work, kept out of the budgets

    var raw: [String: Float] = [:]
    var features = FileFeatures()
    var text = ""                      // content text for words and patterns
    var contentWords: [String] = []
    var visionLabels: [(String, Float)] = []

    init(url: URL, options: ExtractOptions, started: DispatchTime, snapshot: SnapshotBox, cancel: CancelFlag) {
        self.url = url
        self.options = options
        self.started = started
        self.snapshot = snapshot
        self.cancel = cancel
    }

    var expired: Bool {
        FeatureExtractor.ms(since: started) > options.deadline * 1000
    }

    // nothing new and expensive starts after this
    var shouldStop: Bool {
        expired || cancel.isCancelled
    }

    // what a deadline would hand back right now
    func publish() {
        var partial = features
        (partial.sparse, partial.names) = FeatureVectorizer.vectorize(raw)
        partial.raw = raw
        partial.labels = visionLabels
        snapshot.store(partial)
    }

    var remainingSeconds: Double {
        max(0, options.deadline - FeatureExtractor.ms(since: started) / 1000)
    }

    mutating func add(_ feature: String, _ value: Float = 1) {
        guard value > 0 else { return }
        raw[feature] = max(raw[feature] ?? 0, value)
    }

    // signposted stage, time goes into features.timings
    struct Stage {
        let name: StaticString
        let start: DispatchTime
        let state: OSSignpostIntervalState
    }

    func begin(_ name: StaticString) -> Stage {
        let signposter = FeatureExtractor.signposter
        return Stage(name: name, start: DispatchTime.now(), state: signposter.beginInterval(name, id: signposter.makeSignpostID()))
    }

    mutating func end(_ stage: Stage, diagnostic: Bool = false) {
        FeatureExtractor.signposter.endInterval(stage.name, stage.state)
        let ms = FeatureExtractor.ms(since: stage.start)
        features.timings["\(stage.name)", default: 0] += ms
        if diagnostic {
            diagnosticMs += ms
        }
    }

    mutating func run() {
        let metadata = begin("metadata")
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentTypeKey])
        let kind = FileKind.detect(url, values: values)
        features.kind = kind
        addMetadata(kind: kind, values: values)
        end(metadata)
        publish()
        guard !kind.isNameOnly, !shouldStop else { return }

        // can't open it (permissions, deleted), mark it so it doesn't get cached as empty
        do {
            let handle = try FileHandle(forReadingFrom: url)
            try? handle.close()
        } catch {
            features.error = error.localizedDescription
            return
        }

        switch kind {
        case .image:
            extractImage()
        case .pdf:
            extractPDF()
        case .richText:
            extractRichText(size: Int64(values?.fileSize ?? 0))
        case .text, .code:
            extractPlainText()
        default:
            break
        }

        // text we already read is worth the ~1 ms even past the deadline
        if !text.isEmpty && !cancel.isCancelled {
            let tokenize = begin("tokenize")
            addWords()
            end(tokenize)
            publish()
            let patterns = begin("patterns")
            addPatterns()
            end(patterns)
            publish()
        }
    }

    mutating func finish() -> FileFeatures {
        let vectorize = begin("vectorize")
        let (vector, names) = FeatureVectorizer.vectorize(raw)
        end(vectorize)
        features.sparse = vector
        features.names = names
        features.raw = raw
        features.labels = visionLabels
        features.textLength = text.count
        features.languageSample = String(text.prefix(1000))
        if expired {
            features.deadlineHit = true
        }
        if cancel.isCancelled {
            features.cancelled = true
        } else {
            features.summary = makeSummary()
        }
        return features
    }

    static let nameOnlyCode: Set<String> = ["ipynb"]

    // MARK: metadata (every file, about 1-2 ms)

    mutating func addMetadata(kind: FileKind, values: URLResourceValues?) {
        add("kind:\(kind.rawValue)")
        // a plain folder like "2024.Taxes" has no extension, packages (.app) do
        let plainFolder = values?.isDirectory == true && values?.isPackage != true
        let ext = plainFolder ? "" : url.pathExtension.lowercased()
        if !ext.isEmpty && ext.count <= 12 {
            add("ext:\(ext)")
        }
        let filename = url.lastPathComponent
        let words = plainFolder ? TokenNormalizer.words(filename) : TokenNormalizer.filenameWords(filename)
        for word in words {
            if let (token, display) = TokenNormalizer.normalizeWithDisplay(word) {
                add("n:\(token)")
                noteDisplay("n:\(token)", display, token: token)
            }
        }
        for pattern in FilePatterns.namePatterns(filename, keepExtension: plainFolder) {
            add("name:\(pattern)")
        }
        if kind != .folder, let size = values?.fileSize {
            add("size:\(FilePatterns.sizeBucket(Int64(size)))")
        }
        if let origin = options.origin {
            add("from:\(origin)")
        } else if let folder = FilePatterns.originToken(url.deletingLastPathComponent().lastPathComponent) {
            add("from:\(folder)")
        }
        for source in SpotlightInfo.downloadSources(of: url) {
            add("src:\(source)")
        }
        if SpotlightInfo.isScreenshot(url) {
            add("flag:screenshot")
        }
    }

    // MARK: images

    static let ocrLabels: Set<String> = [
        "document", "printed_page", "receipt", "screenshot", "handwriting", "whiteboard",
        "newspaper", "sign", "diagram", "chart",
    ]

    mutating func extractImage() {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return
        }
        // embedded preview if there is one (heic has 320x240), else decode at 384 px
        let thumbnailStage = begin("thumbnail")
        var candidate = Self.thumbnail(source, maxPixel: 384, always: false)
        if let current = candidate, max(current.width, current.height) < 256 || max(current.width, current.height) > 384 {
            // jpeg exif thumbnails are only 160x120, some cameras embed bigger ones
            candidate = Self.thumbnail(source, maxPixel: 384, always: true)
        }
        end(thumbnailStage)
        // svg and ai have no bitmap, name only but still kind:image
        guard let rawThumbnail = candidate else { return }
        // vision sees transparent pixels as black (dark text on alpha = "night sky")
        let thumbnail = Self.opaque(rawThumbnail)
        assert(max(thumbnail.width, thumbnail.height) <= 384, "classified an image over 384 px")
        features.classifySize = CGSize(width: thumbnail.width, height: thumbnail.height)

        guard !shouldStop else { return }
        let classifyStage = begin("classify")
        let labels = Self.classify(thumbnail)
        end(classifyStage)
        visionLabels = labels
        for (label, confidence) in labels {
            add("v:\(label)", confidence)
        }
        publish()

        let reason = ocrReason(labels: labels)
        features.ocrReason = reason
        // .fast ocr can't be cancelled, don't start it this close to the deadline
        let ocrFits = remainingSeconds > Self.ocrReserve
        guard (reason != nil && ocrFits || options.diagBoxes) && !shouldStop else {
            if reason != nil && !ocrFits {
                features.ocrReason = "\(reason!) (skipped: deadline)"
            }
            return
        }

        // not IfAbsent, that returns the tiny embedded preview
        let willOCR = reason != nil && ocrFits
        let imageStage = begin("ocrImage")
        let bigImage = Self.thumbnail(source, maxPixel: 1600, always: true).map(Self.opaque)
        end(imageStage, diagnostic: !willOCR)
        guard let bigImage else { return }
        if options.diagBoxes {
            features.diagSize = CGSize(width: bigImage.width, height: bigImage.height)
            let boxesStage = begin("diagBoxes")
            features.textBoxes = Self.countTextBoxes(bigImage)
            end(boxesStage, diagnostic: true)
        }
        if willOCR && !shouldStop {
            features.ocrSize = CGSize(width: bigImage.width, height: bigImage.height)
            let ocrStage = begin("ocr")
            let recognized = Self.recognizeText(bigImage)
            end(ocrStage)
            append(recognized)
        }
    }

    // the slowest dense-text ocr measured on the m3 was ~0.35 s
    static let ocrReserve = 0.5

    // v1 gate, a document-ish label or the screenshot/scan hints
    func ocrReason(labels: [(String, Float)]) -> String? {
        if let label = labels.first(where: { Self.ocrLabels.contains($0.0) }) {
            return "label \(label.0)"
        }
        if raw["flag:screenshot"] != nil { return "flag:screenshot" }
        if raw["name:screenshot"] != nil { return "name:screenshot" }
        if raw["name:scan"] != nil { return "name:scan" }
        return nil
    }

    // flatten alpha onto white (~1 ms at 384 px)
    static func opaque(_ image: CGImage) -> CGImage {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return image
        default:
            break
        }
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }

    static func thumbnail(_ source: CGImageSource, maxPixel: Int, always: Bool) -> CGImage? {
        let options: [CFString: Any] = [
            (always ? kCGImageSourceCreateThumbnailFromImageAlways : kCGImageSourceCreateThumbnailFromImageIfAbsent): true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // labels >= 0.1, top 10, ties sorted by name so the order is stable
    static func classify(_ image: CGImage) -> [(String, Float)] {
        let request = VNClassifyImageRequest()
        request.revision = VNClassifyImageRequestRevision2
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return []
        }
        let kept = (request.results ?? [])
            .filter { $0.confidence >= 0.1 }
            .map { ($0.identifier, $0.confidence) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        return Array(kept.prefix(10))
    }

    // .fast with no language correction, ~10-30 ms instead of 90-300
    static func recognizeText(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.revision = VNRecognizeTextRequestRevision3
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return ""
        }
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    static func countTextBoxes(_ image: CGImage) -> Int {
        let request = VNDetectTextRectanglesRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return request.results?.count ?? 0
    }

    // MARK: documents

    mutating func extractPDF() {
        let textStage = begin("pdfText")
        let document = PDFDocument(url: url)
        var pageText = ""
        if let document {
            for index in 0..<min(2, document.pageCount) {
                pageText += (document.page(at: index)?.string ?? "") + "\n"
                if pageText.count >= 4000 { break }
            }
        }
        end(textStage)
        guard let document else {
            features.error = "not a readable pdf"
            return
        }
        // password protected, nothing to read so name only
        if document.isLocked {
            return
        }
        if pageText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 50 {
            append(String(pageText.prefix(4000)))
            return
        }

        // a scan, render page 1 at 1600 px and ocr it
        guard !shouldStop, let page = document.page(at: 0) else { return }
        features.ocrReason = "scanned pdf"
        let renderStage = begin("pdfRender")
        let rendered = page.thumbnail(of: NSSize(width: 1600, height: 1600), for: .mediaBox)
        var rect = CGRect(origin: .zero, size: rendered.size)
        let image = rendered.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        end(renderStage)
        guard let image, !shouldStop else { return }
        guard remainingSeconds > Self.ocrReserve else {
            features.ocrReason = "scanned pdf (skipped: deadline)"
            return
        }
        features.ocrSize = CGSize(width: image.width, height: image.height)
        let ocrStage = begin("ocr")
        let recognized = Self.recognizeText(image)
        end(ocrStage)
        append(recognized)
    }

    mutating func extractRichText(size: Int64) {
        // big documents stay name only
        guard size <= 5_000_000 else { return }
        let type: NSAttributedString.DocumentType
        switch url.pathExtension.lowercased() {
        case "docx": type = .officeOpenXML
        case "doc": type = .docFormat
        case "odt": type = .openDocument
        default: type = .rtf
        }
        let stage = begin("richText")
        let document = try? NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil)
        end(stage)
        append(String((document?.string ?? "").prefix(4000)))
    }

    mutating func extractPlainText() {
        // notebooks are name only
        guard !Self.nameOnlyCode.contains(url.pathExtension.lowercased()) else { return }
        let stage = begin("readText")
        var string = ""
        if let handle = try? FileHandle(forReadingFrom: url) {
            let data = (try? handle.read(upToCount: 16 * 1024)) ?? Data()
            try? handle.close()
            let ext = url.pathExtension.lowercased()
            switch TextDecoding.decode(data) {
            case .text(let decoded):
                string = ext == "html" || ext == "htm" ? FilePatterns.stripHTML(decoded) : decoded
            case .binary:
                // a .ts that is really an mpeg transport stream is a video
                if ext == "ts" && TextDecoding.isTransportStream(data) {
                    raw["kind:\(FileKind.code.rawValue)"] = nil
                    features.kind = .movie
                    add("kind:\(FileKind.movie.rawValue)")
                }
            }
        }
        end(stage)
        append(string)
    }

    mutating func append(_ more: String) {
        guard !more.isEmpty else { return }
        text += text.isEmpty ? more : "\n" + more
    }

    // MARK: content words and patterns

    mutating func addWords() {
        var counts: [String: Int] = [:]
        var order: [String] = []
        var displays: [String: String] = [:]
        var kept = 0
        let content = text
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = content
        // the first ~600 tokens, log(1 + tf)
        tokenizer.enumerateTokens(in: content.startIndex..<content.endIndex) { range, _ in
            if let (token, display) = TokenNormalizer.normalizeWithDisplay(String(content[range])) {
                if counts[token] == nil {
                    order.append(token)
                    displays[token] = display
                }
                counts[token, default: 0] += 1
                kept += 1
            }
            return kept < 600
        }
        for token in order {
            add("c:\(token)", Float(log(1 + Double(counts[token] ?? 1))))
            noteDisplay("c:\(token)", displays[token] ?? token, token: token)
        }
        contentWords = order
    }

    // the word a folded token came from, when they differ
    mutating func noteDisplay(_ name: String, _ display: String, token: String) {
        if display != token && features.display[name] == nil {
            features.display[name] = display
        }
    }

    mutating func addPatterns() {
        for pattern in FilePatterns.contentPatterns(text) {
            add("pat:\(pattern)")
        }
    }

    // filename words + top 3 labels + ~20 content words, max 30 (~9 ms)
    // the actor checks it's english before embedding
    func makeSummary() -> String {
        var words: [String] = []
        for word in TokenNormalizer.filenameWords(url.lastPathComponent) {
            if let token = TokenNormalizer.normalize(word) {
                words.append(token)
            }
        }
        for (label, _) in visionLabels.prefix(3) {
            words.append(contentsOf: label.split(separator: "_").map(String.init))
        }
        words.append(contentsOf: contentWords.prefix(20))
        return words.prefix(30).joined(separator: " ")
    }
}

// MARK: patterns

enum FilePatterns {
    private static func regex(_ pattern: String, caseInsensitive: Bool = true) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    // on the raw name, these need the separators
    private static let datePattern = regex(#"\d{4}[-_.]\d{2}[-_.]\d{2}"#)
    private static let cameraPattern = regex(#"^(IMG|DSC|PXL)_"#, caseInsensitive: false)
    private static let screenshotPattern = regex(#"screen ?shot"#)
    private static let screenRecordingPattern = regex(#"screen ?recording"#)
    // on split words so camelCase counts ("ReceiptScan") but "scanner" doesn't
    private static let scanPattern = regex(#"\bscan(ned)?\b"#)
    private static let copyPattern = regex(#"\bcopy\b"#)
    private static let versionPattern = regex(#"\b(v\d+|final|draft)\b"#)

    static func namePatterns(_ filename: String, keepExtension: Bool = false) -> [String] {
        let base = keepExtension ? filename : (filename as NSString).deletingPathExtension
        let words = TokenNormalizer.words(base).joined(separator: " ")
        var found: [String] = []
        func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
            expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        if matches(datePattern, base) { found.append("date") }
        if matches(cameraPattern, base) { found.append("camera") }
        if matches(screenshotPattern, base) { found.append("screenshot") }
        if matches(screenRecordingPattern, base) { found.append("screenrecording") }
        if matches(scanPattern, words) { found.append("scan") }
        if matches(copyPattern, words) { found.append("copy") }
        if matches(versionPattern, words) { found.append("version") }
        return found
    }

    static func sizeBucket(_ bytes: Int64) -> String {
        switch bytes {
        case ..<100_000: return "lt100k"
        case ..<1_000_000: return "lt1m"
        case ..<10_000_000: return "lt10m"
        case ..<100_000_000: return "lt100m"
        default: return "ge100m"
        }
    }

    // "Downloads" -> downloads, "05 Résumés" -> 05_resumes
    static func originToken(_ folder: String) -> String? {
        let words = folder.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        guard !words.isEmpty else { return nil }
        return String(words.joined(separator: "_").prefix(40))
    }

    // price plus a total/tax word anywhere, ocr splits them onto separate lines
    // matches 14.55, 1,250.00 and 1.234,56 but not 1,234 or 1.234.56
    private static let pricePattern = regex(#"(?<![\d.,])(?:\d{1,3}(?:,\d{3})+\.\d{2}|\d{1,3}(?:\.\d{3})+,\d{2}|\d+[.,]\d{2})(?![\d])"#)
    private static let moneyWordPattern = regex(#"\b(total|tax|subtotal|amount)\b"#)
    private static let taxFormPattern = regex(#"\b(W-?2|1099|1040)\b"#)
    private static let numericDatePattern = regex(#"\b(\d{4}[-/.]\d{1,2}[-/.]\d{1,2}|\d{1,2}[-/.]\d{1,2}[-/.](\d{4}|\d{2}))\b"#)
    private static let wordDatePattern = regex(#"\b(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.? \d{1,2}(st|nd|rd|th)?,? \d{4}\b"#)
    // anchored on the left, otherwise long runs (dna, hex, base64) take seconds
    private static let emailPattern = regex(#"(?<![A-Z0-9._%+-])[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#)
    private static let phonePattern = regex(#"(\+\d{1,3}[ .-]?)?\(?\b\d{3}\)?[ .-]\d{3}[ .-]\d{4}\b"#)

    static func contentPatterns(_ text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        func matches(_ expression: NSRegularExpression) -> Bool {
            expression.firstMatch(in: text, range: range) != nil
        }
        var found: [String] = []
        if matches(pricePattern) && matches(moneyWordPattern) { found.append("money") }
        if matches(taxFormPattern) { found.append("taxform") }
        if matches(numericDatePattern) || matches(wordDatePattern) { found.append("date") }
        if matches(emailPattern) { found.append("email") }
        if matches(phonePattern) { found.append("phone") }
        return found
    }

    // a script or comment cut off by the 16 KB read runs to the end
    private static let scriptPattern = regex(#"<(script|style)\b[^>]*>[\s\S]*?(?:</\1\s*>|$)"#)
    private static let commentPattern = regex(#"<!--[\s\S]*?(?:-->|$)"#)
    private static let tagPattern = regex(#"<[^<>]*>"#)

    // strip tags ourselves, the html importer loads remote stuff and is slow
    static func stripHTML(_ html: String) -> String {
        var text = commentPattern.stringByReplacingMatches(in: html, range: NSRange(html.startIndex..., in: html), withTemplate: " ")
        text = scriptPattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        text = tagPattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        for (entity, character) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " ")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text
    }
}

// MARK: spotlight and its xattr fallbacks

enum SpotlightInfo {
    // cdns say nothing about where a file came from
    static let cdnHosts = ["googleusercontent", "cloudfront", "akamai", "amazonaws"]
    // second-level suffixes like co.uk keep three labels
    static let secondLevelSuffixes: Set<String> = ["co", "com", "ac", "gov", "edu", "org", "net", "ne", "or"]

    static func downloadSources(of url: URL) -> [String] {
        var sources: [String] = []
        for link in whereFroms(url).prefix(2) {
            for source in sourceFeatures(link) where !sources.contains(source) {
                sources.append(source)
            }
        }
        return sources
    }

    // "https://www.amazon.co.uk/x" -> ["amazon.co.uk", "amazon"]
    static func sourceFeatures(_ link: String) -> [String] {
        guard let host = URL(string: link)?.host?.lowercased(), host.contains(".") else { return [] }
        guard !cdnHosts.contains(where: { host.contains($0) }) else { return [] }
        // a router, nas or dev server says nothing (10.0.0.5, [::1])
        guard !host.contains(":"), !host.split(separator: ".").allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return [] }
        var labels = host.split(separator: ".").map(String.init)
        if labels.first == "www" {
            labels.removeFirst()
        }
        guard labels.count >= 2 else { return [] }
        let keep = labels.count >= 3 && labels.last!.count == 2 && secondLevelSuffixes.contains(labels[labels.count - 2]) ? 3 : 2
        let domain = labels.suffix(keep)
        // the name part only, not com / co.uk
        let name = domain.first!
        return [domain.joined(separator: "."), name]
    }

    static func whereFroms(_ url: URL) -> [String] {
        if let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL),
           let value = MDItemCopyAttribute(item, kMDItemWhereFroms) as? [String], !value.isEmpty {
            return value
        }
        // spotlight hasn't indexed it (or never will, like in $TMPDIR)
        return xattrPlist(url, name: "com.apple.metadata:kMDItemWhereFroms") as? [String] ?? []
    }

    static func isScreenshot(_ url: URL) -> Bool {
        // no sdk constant exists for this one
        if let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL),
           let value = MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString) as? Bool {
            return value
        }
        return xattrPlist(url, name: "com.apple.metadata:kMDItemIsScreenCapture") as? Bool ?? false
    }

    static func xattrPlist(_ url: URL, name: String) -> Any? {
        url.withUnsafeFileSystemRepresentation { path -> Any? in
            guard let path else { return nil }
            let size = getxattr(path, name, nil, 0, 0, 0)
            guard size > 0, size < 1_000_000 else { return nil }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, 0) }
            guard read == size else { return nil }
            return try? PropertyListSerialization.propertyList(from: data, format: nil)
        }
    }
}

// MARK: text decoding

enum TextDecoding {
    enum Result {
        case text(String)
        case binary
    }

    // utf-16 with a bom, binary if there's a nul, utf-8, else windows-1252
    static func decode(_ data: Data) -> Result {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return .text(String(data: data, encoding: .utf16) ?? "")
        }
        if data.contains(0) {
            return .binary
        }
        // the read may have cut a multibyte character at the end
        for trim in 0...3 where data.count > trim {
            if let string = String(data: data.dropLast(trim), encoding: .utf8) {
                return .text(string)
            }
        }
        return .text(String(data: data, encoding: .windowsCP1252) ?? "")
    }

    // mpeg-2 transport streams have a 0x47 sync byte every 188 bytes
    static func isTransportStream(_ data: Data) -> Bool {
        data.count > 188 && data[data.startIndex] == 0x47 && data[data.startIndex + 188] == 0x47
    }
}
