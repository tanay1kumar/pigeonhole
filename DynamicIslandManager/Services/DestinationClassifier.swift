import Foundation
import NaturalLanguage
import Vision

enum Level: String, Equatable {
    case confident, unsure, noIdea
}

struct RankedDestination: Equatable {
    let destination: Destination
    let raw: Double
    let p: Double
}

struct Ranking: Equatable {
    var items: [RankedDestination]     // best first
    var level: Level
    var why: String
    var floor: Double = 0              // the top's evidence score the levels were judged on (tests, eval)
}

// scoring knobs (the plan §4.5). block weights change feature vectors, the rest only change scoring
struct ScoringParams: Equatable {
    var alpha: Float = 2.0               // weight of the starting profile in the centroid
    var beta: Float = 0.5                // weight of negatives
    var lambdaKScale: Float = 0.5        // λ_k(n) = scale · n / (n + 3)
    var lambdaE: Float = 0.3             // dense term
    var temperature: Float = 0.05        // softmax T
    var confidentP1: Float = 0.70
    var confidentMargin: Float = 0.10
    var confidentFloor: Float = 0.15
    var unsureFloor: Float = 0.08
    var labelCap = 25                    // vision labels per destination profile
    var blockWeights = BlockWeights.standard
}

// what a destination looks like before anything was learned (the plan §4.4)
struct DestinationProfile {
    let vector: SparseVector             // unit length
    let names: [UInt32: String]
    let dense: [Float]?                  // unit length prior q̂
    let packs: [String]
    let visionLabels: [(String, Float)]
}

// ranks a file's features against the destinations and learns from what the user does.
// rank takes a snapshot of the destinations; it never reads DestinationStore
actor DestinationClassifier {
    let store: LearningStore
    var params = ScoringParams()

    private var profiles: [String: DestinationProfile] = [:]   // key: id + name + hint + weights
    private var wordEmbedding: NLEmbedding?
    private var sentenceEmbedding: NLEmbedding?
    private var triedEmbeddings = false
    private var visionTaxonomy: [String]?

    init(store: LearningStore, params: ScoringParams = ScoringParams()) {
        self.store = store
        self.params = params
    }

    func setParams(_ newParams: ScoringParams) {
        if newParams.blockWeights != params.blockWeights || newParams.labelCap != params.labelCap {
            profiles.removeAll()
        }
        params = newParams
    }

    // MARK: api

    func rank(_ features: FileFeatures, among destinations: [Destination]) -> Ranking {
        guard !destinations.isEmpty else {
            return Ranking(items: [], level: .noIdea, why: "")
        }
        let learned = store.snapshot()
        let x = features.sparse
        let dense = features.dense

        struct Scored {
            let index: Int
            let destination: Destination
            let cent: Float
            let knn: Float
            let lambdaK: Float
            var denseRaw: Float?
            let centroid: SparseVector
            let contentCent: Float
            let contentKnn: Float
        }

        // the levels need evidence beyond what every file of a type shares: one learned photo made
        // every photo "confident" through kind, ext, the folder it came from and its size alone
        let content = Self.contentFlags(features)

        var scored: [Scored] = []
        for (index, destination) in destinations.enumerated() {
            let profile = self.profile(for: destination)
            let data = learned[destination.id]
            let examples = data?.examples ?? []
            let negatives = data?.negatives ?? []

            // centroid: α·p + Σ w·x − β·Σ v·n, negatives clamped away, unit length
            var centroid = SparseVector(indices: profile.vector.indices, values: profile.vector.values.map { $0 * params.alpha })
            for example in examples {
                centroid = centroid.adding(example.vector, scale: example.weight)
            }
            for negative in negatives {
                centroid = centroid.adding(negative.vector, scale: -params.beta * negative.value)
            }
            centroid = Self.clampedUnit(centroid)

            let cent = centroid.isEmpty ? 0 : x.dot(centroid) / max(x.norm, 1e-9)
            // k nearest examples, unweighted mean of the top min(3, n)
            let similarities = examples.map { x.cosine($0.vector) }.sorted(by: >)
            let k = min(3, similarities.count)
            let knn = k > 0 ? similarities.prefix(k).reduce(0, +) / Float(k) : 0
            // the same two, counting only the file's content features
            let contentCent = centroid.isEmpty ? 0 : Self.maskedDot(x, centroid, content) / max(x.norm, 1e-9)
            let contentSimilarities = examples.map {
                Self.maskedDot(x, $0.vector, content) / max(x.norm * $0.vector.norm, 1e-9)
            }.sorted(by: >)
            let contentKnn = k > 0 ? contentSimilarities.prefix(k).reduce(0, +) / Float(k) : 0
            let n = Float(examples.count)
            let lambdaK = params.lambdaKScale * n / (n + 3)

            var denseRaw: Float?
            if let dense {
                var target = profile.dense.map { $0.map { $0 * params.alpha } }
                if let sum = data?.denseSum, sum.count == dense.count {
                    target = target.map { Self.add($0, sum) } ?? sum
                }
                if let target, target.count == dense.count {
                    denseRaw = Self.cosine(dense, target)
                }
            }
            scored.append(Scored(index: index, destination: destination, cent: cent, knn: knn, lambdaK: lambdaK,
                                 denseRaw: denseRaw, centroid: centroid, contentCent: contentCent, contentKnn: contentKnn))
        }

        // center the dense term per file: unrelated short texts still score 0.04-0.56
        let denseValues = scored.compactMap(\.denseRaw)
        let denseMean = denseValues.isEmpty ? 0 : denseValues.reduce(0, +) / Float(denseValues.count)

        var raws: [Double] = []
        var floors: [Double] = []
        for item in scored {
            let centered = item.denseRaw.map { $0 - denseMean } ?? 0
            let base = item.cent + item.lambdaK * item.knn
            raws.append(Double(base + params.lambdaE * centered))
            // ranking uses everything; the floors only content, and the dense term only when it helps
            let evidence = item.contentCent + item.lambdaK * item.contentKnn
            floors.append(Double(evidence + params.lambdaE * max(0, centered)))
        }

        // softmax over raw / T
        let temperature = Double(max(params.temperature, 1e-4))
        let maxRaw = raws.max() ?? 0
        let exps = raws.map { exp(($0 - maxRaw) / temperature) }
        let total = exps.reduce(0, +)
        let probabilities = exps.map { total > 0 ? $0 / total : 0 }

        // best first, ties by destination order
        let order = scored.indices.sorted { a, b in
            raws[a] != raws[b] ? raws[a] > raws[b] : a < b
        }
        let items = order.map { RankedDestination(destination: scored[$0].destination, raw: raws[$0], p: probabilities[$0]) }

        let top = order[0]
        let raw1 = raws[top]
        let raw2 = order.count > 1 ? raws[order[1]] : 0
        let p1 = probabilities[top]
        let floor1 = floors[top]
        let level: Level
        if p1 >= Double(params.confidentP1) && raw1 - raw2 >= Double(params.confidentMargin) && floor1 >= Double(params.confidentFloor) {
            level = .confident
        } else if floor1 >= Double(params.unsureFloor) {
            level = .unsure
        } else {
            level = .noIdea
        }

        let best = scored[top]
        let why = Self.whyText(features: features, centroid: best.centroid, cent: best.cent, knnPart: best.lambdaK * best.knn)
        return Ranking(items: items, level: level, why: why, floor: floor1)
    }

    func record(_ batch: [LearningEvent]) {
        store.record(batch)
        for event in batch {
            print("learn: \(event.kind.rawValue) dest=\(event.chosenId) w=\(Self.format(event.weight))"
                  + (event.kind == .corrected && event.suggestedId != nil && event.suggestedId != event.chosenId
                     ? " neg=\(event.suggestedId!):\(Self.format(LearningStore.negativeValue))" : ""))
        }
    }

    @discardableResult
    func undoLastBatch() -> Bool {
        store.undoLastBatch()
    }

    func removeData(for id: String) {
        store.removeData(for: id)
        profiles = profiles.filter { !$0.key.hasPrefix(id + "\u{1}") }
    }

    func reset() {
        store.reset()
    }

    func flush() {
        store.flush()
    }

    // word and sentence embeddings, memory-mapped, about 0 MB of footprint
    func prewarm() {
        loadEmbeddings()
        _ = taxonomy()
    }

    func profileFor(_ destination: Destination) -> DestinationProfile {
        profile(for: destination)
    }

    // MARK: profiles

    static let genericWords: Set<String> = [
        "stuff", "misc", "other", "file", "doc", "document", "new", "old", "my", "thing", "temp", "folder",
    ]

    private func profile(for destination: Destination) -> DestinationProfile {
        let key = [destination.id, destination.name, destination.hint ?? ""].joined(separator: "\u{1}")
        if let cached = profiles[key] {
            return cached
        }
        // a renamed or re-hinted destination drops its old profile
        profiles = profiles.filter { !$0.key.hasPrefix(destination.id + "\u{1}") }
        let built = buildProfile(name: destination.name, hint: destination.hint)
        profiles[key] = built
        return built
    }

    func buildProfile(name: String, hint: String?) -> DestinationProfile {
        loadEmbeddings()
        var raw: [String: Float] = [:]
        func add(_ feature: String, _ value: Float) {
            raw[feature] = max(raw[feature] ?? 0, value)
        }

        // 1. name and hint words, generic ones skipped; digits kept (course codes, years)
        let sources = [name, hint ?? ""]
        var surfaceWords: [String] = []     // lowercased, before plural folding, for the label mapping
        var normalizedWords: [String] = []
        var matchWords: [[String]] = []
        for source in sources {
            var words: [String] = []
            // split exactly like filenames, so "CS101" and "MathHomework" match their files
            for part in TokenNormalizer.words(source) {
                let surface = part.precomposedStringWithCanonicalMapping
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                guard let token = TokenNormalizer.normalize(surface, keepDigits: true) else { continue }
                words.append(token)
                guard !Self.genericWords.contains(token) else { continue }
                normalizedWords.append(token)
                surfaceWords.append(surface)
                add("n:\(token)", 1)
                add("c:\(token)", 1)
            }
            matchWords.append(words)
        }

        // 2. keyword packs
        var packs: [KeywordPack] = []
        for (index, words) in matchWords.enumerated() {
            for pack in KeywordPacks.matches(words: words, name: index == 0 ? name : "") where !packs.contains(where: { $0.name == pack.name }) {
                packs.append(pack)
            }
        }
        for pack in packs {
            for seed in pack.seeds {
                for part in seed.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                    if let token = TokenNormalizer.normalize(String(part), keepDigits: true) {
                        add("c:\(token)", 0.6)
                        add("n:\(token)", 0.6)
                    }
                }
            }
            for extra in pack.extras {
                add(extra, 0.5)
            }
        }

        // 3. vision labels near the name and hint words
        let labels = mapToVisionLabels(surfaceWords)
        for (label, weight) in labels {
            add("v:\(label)", weight)
        }

        let (vector, names) = FeatureVectorizer.vectorize(raw, weights: params.blockWeights)

        // 4. dense prior: name + hint + each matched pack's description
        let priorText = ([name, hint ?? ""] + packs.map(\.description)).filter { !$0.isEmpty }.joined(separator: " ")
        let dense = embed(priorText)
        return DestinationProfile(vector: vector, names: names, dense: dense, packs: packs.map(\.name), visionLabels: labels)
    }

    // the plan §4.4 step 3 (same rule as tools/bench/probes/label_mapping.swift): surface and plural-folded word,
    // smaller distance wins; a label's word is the whole label if known, else its last "_" part (half weight,
    // never exact); keep d <= 0.9 or exact/plural; weight 1 - d/2, exact 1.0; top labelCap
    func mapToVisionLabels(_ words: [String]) -> [(String, Float)] {
        guard let embedding = wordEmbedding, !words.isEmpty else { return [] }
        var best: [String: Float] = [:]
        for surface in words {
            let folded = surface.count > 3 && surface.hasSuffix("s") && !surface.hasSuffix("ss") ? String(surface.dropLast()) : surface
            let forms = (surface == folded ? [surface] : [surface, folded]).filter { embedding.contains($0) }
            guard !forms.isEmpty else { continue }
            for label in taxonomy() {
                var labelWord: String?
                var lastWord = false
                if embedding.contains(label) {
                    labelWord = label
                } else if let last = label.split(separator: "_").last.map(String.init), embedding.contains(last) {
                    labelWord = last
                    lastWord = true
                }
                guard let labelWord else { continue }
                var distance = Double.infinity
                var exact = false
                for form in forms {
                    distance = min(distance, embedding.distance(between: form, and: labelWord, distanceType: .cosine))
                    if !lastWord && (labelWord == form || labelWord + "s" == form || form + "s" == labelWord) {
                        exact = true
                    }
                }
                guard distance.isFinite, distance <= 0.9 || exact else { continue }
                var weight = exact ? 1 : Float(1 - distance / 2)
                if lastWord {
                    weight /= 2
                }
                best[label] = max(best[label] ?? 0, weight)
            }
        }
        return best.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(params.labelCap)
            .map { ($0.key, $0.value) }
    }

    private func taxonomy() -> [String] {
        if let visionTaxonomy {
            return visionTaxonomy
        }
        let request = VNClassifyImageRequest()
        request.revision = VNClassifyImageRequestRevision2
        let identifiers = (try? request.supportedIdentifiers()) ?? []
        visionTaxonomy = identifiers.sorted()
        return visionTaxonomy ?? []
    }

    private func loadEmbeddings() {
        guard !triedEmbeddings else { return }
        triedEmbeddings = true
        wordEmbedding = NLEmbedding.wordEmbedding(for: .english)
        sentenceEmbedding = NLEmbedding.sentenceEmbedding(for: .english)
    }

    private func embed(_ text: String) -> [Float]? {
        guard !text.isEmpty, let vector = sentenceEmbedding?.vector(for: text) else { return nil }
        var squares: Double = 0
        for value in vector {
            squares += value * value
        }
        let length = squares.squareRoot()
        return length > 0 ? vector.map { Float($0 / length) } : nil
    }

    // MARK: evidence

    // extensions many destinations share. anything else (blend, stl, psd...) says something on its own
    static let commonExtensions: Set<String> = [
        "pdf", "heic", "heif", "jpg", "jpeg", "png", "gif", "tif", "tiff", "webp", "doc", "docx", "txt", "rtf",
        "md", "pages", "csv", "xls", "xlsx", "numbers", "ppt", "pptx", "key", "mov", "mp4", "m4v", "mp3", "m4a",
        "wav", "aac", "zip",
    ]
    // name patterns that only say what kind of file it is
    static let genericNamePatterns: Set<String> = ["date", "camera", "copy", "version"]
    // content patterns most documents have: an invoice and a resume both have an email and a date
    static let genericContentPatterns: Set<String> = ["email", "phone", "date"]

    // per index of the file's vector: does it count as evidence for the levels
    static func contentFlags(_ features: FileFeatures) -> [Bool] {
        features.sparse.indices.map { index in
            guard let name = features.names[index], let colon = name.firstIndex(of: ":") else { return true }
            let token = String(name[name.index(after: colon)...])
            switch name[..<colon] {
            case "kind", "from", "size": return false
            case "ext": return !commonExtensions.contains(token)
            case "name": return !genericNamePatterns.contains(token)
            case "pat": return !genericContentPatterns.contains(token)
            default: return true
            }
        }
    }

    // x·y over the file's indices flagged true
    static func maskedDot(_ x: SparseVector, _ y: SparseVector, _ flags: [Bool]) -> Float {
        var sum: Float = 0
        var i = 0, j = 0
        while i < x.indices.count && j < y.indices.count {
            let a = x.indices[i], b = y.indices[j]
            if a == b {
                if flags[i] {
                    sum += x.values[i] * y.values[j]
                }
                i += 1
                j += 1
            } else if a < b {
                i += 1
            } else {
                j += 1
            }
        }
        return sum
    }

    // MARK: math

    static func clampedUnit(_ vector: SparseVector) -> SparseVector {
        var indices: [UInt32] = []
        var values: [Float] = []
        for (index, value) in zip(vector.indices, vector.values) where value > 0 {
            indices.append(index)
            values.append(value)
        }
        return SparseVector(indices: indices, values: values).normalized()
    }

    static func add(_ a: [Float], _ b: [Float]) -> [Float] {
        zip(a, b).map { $0 + $1 }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0, aa: Float = 0, bb: Float = 0
        for index in a.indices {
            dot += a[index] * b[index]
            aa += a[index] * a[index]
            bb += b[index] * b[index]
        }
        let lengths = (aa * bb).squareRoot()
        return lengths > 0 ? dot / lengths : 0
    }

    static func format(_ value: Float) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2g", value)
    }

    // MARK: why

    // a kind we can't name says nothing: no "File"
    static let kindNames: [FileKind: String] = [
        .image: "Photo", .pdf: "PDF", .richText: "Document", .text: "Text", .code: "Code",
        .presentation: "Slides", .spreadsheet: "Spreadsheet", .audio: "Audio", .movie: "Video",
        .archive: "Archive", .folder: "Folder",
    ]

    // patterns in words, not their internal names
    static let phrases: [String: String] = [
        "name:camera": "camera photo", "name:date": "date in name", "name:copy": "a copy",
        "name:version": "draft or version in name", "name:scan": "scan", "name:screenshot": "screenshot",
        "name:screenrecording": "screen recording",
        "pat:money": "prices", "pat:taxform": "tax form", "pat:date": "dates", "pat:email": "email address",
        "pat:phone": "phone number",
    ]

    // what can be said in words; the folder a file came from and its size never take a place
    static let sayable: Set<String> = ["v", "c", "n", "src", "flag", "kind", "ext", "name", "pat"]

    // the top 2-3 contributions x_j·m_j, grouped by namespace
    static func whyText(features: FileFeatures, centroid: SparseVector, cent: Float, knnPart: Float) -> String {
        var contributions: [(String, Float)] = []
        var i = 0, j = 0
        let x = features.sparse
        while i < x.indices.count && j < centroid.indices.count {
            let a = x.indices[i], b = centroid.indices[j]
            if a == b {
                let value = x.values[i] * centroid.values[j]
                if value > 0, let name = features.names[a], let colon = name.firstIndex(of: ":"),
                   sayable.contains(String(name[..<colon])) {
                    contributions.append((name, value))
                }
                i += 1
                j += 1
            } else if a < b {
                i += 1
            } else {
                j += 1
            }
        }
        contributions.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        let top = Array(contributions.prefix(3))
        let sum = top.reduce(0) { $0 + $1.1 }
        guard sum >= 0.02 else {
            if knnPart > 0 && knnPart >= cent {
                return "like files you sent here"
            }
            return kindNames[features.kind] ?? ""
        }
        // the word the file actually had, not its folded token
        func shown(_ namespace: String, _ token: String) -> String {
            features.display["\(namespace):\(token)"] ?? token
        }

        var groups: [(namespace: String, tokens: [String])] = []
        for (name, _) in top {
            guard let colon = name.firstIndex(of: ":") else { continue }
            let namespace = String(name[..<colon])
            let token = String(name[name.index(after: colon)...])
            if let index = groups.firstIndex(where: { $0.namespace == namespace }) {
                groups[index].tokens.append(token)
            } else {
                groups.append((namespace, [token]))
            }
        }
        var parts: [String] = []
        for group in groups {
            let tokens = group.tokens
            switch group.namespace {
            case "v": parts.append("looks like: " + tokens.map { $0.replacingOccurrences(of: "_", with: " ") }.joined(separator: ", "))
            case "c": parts.append("mentions: " + tokens.map { shown("c", $0) }.joined(separator: ", "))
            case "n": parts.append("name has: " + tokens.map { shown("n", $0) }.joined(separator: ", "))
            case "src": parts.append("from " + (tokens.first(where: { $0.contains(".") }) ?? tokens[0]))
            case "flag": parts.append(tokens.contains("screenshot") ? "screenshot" : tokens.joined(separator: ", "))
            case "kind", "ext":
                if let kind = kindNames[features.kind] {
                    parts.append(kind)
                } else if group.namespace == "ext" {
                    parts.append(".\(tokens[0]) file")
                }
            case "name", "pat": parts.append(tokens.map { phrases["\(group.namespace):\($0)"] ?? $0 }.joined(separator: ", "))
            default: break
            }
        }
        // kind and ext both say "PDF"
        var seen = Set<String>()
        return parts.filter { seen.insert($0).inserted }.joined(separator: " · ")
    }
}
