import Foundation

// feature names are "namespace:token". this turns a file's (or a destination's) raw features
// into one hashed, weighted, unit-length sparse vector (the plan §4.3).

struct SparseVector: Equatable {
    var indices: [UInt32] = []   // sorted ascending, unique
    var values: [Float] = []

    var isEmpty: Bool { indices.isEmpty }

    var norm: Float {
        var sum: Float = 0
        for value in values { sum += value * value }
        return sum.squareRoot()
    }

    func normalized() -> SparseVector {
        let length = norm
        guard length > 0 else { return self }
        return SparseVector(indices: indices, values: values.map { $0 / length })
    }

    // merge-join over the sorted indices
    func dot(_ other: SparseVector) -> Float {
        var i = 0, j = 0
        var sum: Float = 0
        while i < indices.count && j < other.indices.count {
            let a = indices[i], b = other.indices[j]
            if a == b {
                sum += values[i] * other.values[j]
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

    func cosine(_ other: SparseVector) -> Float {
        let lengths = norm * other.norm
        return lengths > 0 ? dot(other) / lengths : 0
    }

    // a·self + b·other, indices merged
    func adding(_ other: SparseVector, scale: Float = 1) -> SparseVector {
        var result = SparseVector()
        result.indices.reserveCapacity(indices.count + other.indices.count)
        result.values.reserveCapacity(indices.count + other.indices.count)
        var i = 0, j = 0
        while i < indices.count || j < other.indices.count {
            if j >= other.indices.count || (i < indices.count && indices[i] < other.indices[j]) {
                result.indices.append(indices[i])
                result.values.append(values[i])
                i += 1
            } else if i >= indices.count || other.indices[j] < indices[i] {
                result.indices.append(other.indices[j])
                result.values.append(other.values[j] * scale)
                j += 1
            } else {
                result.indices.append(indices[i])
                result.values.append(values[i] + other.values[j] * scale)
                i += 1
                j += 1
            }
        }
        return result
    }

    // builds a vector from unsorted pairs, summing repeats
    init(pairs: [(UInt32, Float)]) {
        let sorted = pairs.sorted { $0.0 < $1.0 }
        for (index, value) in sorted {
            if let last = indices.last, last == index {
                values[values.count - 1] += value
            } else {
                indices.append(index)
                values.append(value)
            }
        }
    }

    init(indices: [UInt32] = [], values: [Float] = []) {
        self.indices = indices
        self.values = values
    }
}

enum FeatureHash {
    // fnv-1a 64 with a wrapping multiply. never Hasher or hashValue: those are seeded per process
    static func fnv1a64(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return hash
    }

    // 2^20 buckets
    static func index(_ feature: String) -> UInt32 {
        UInt32(truncatingIfNeeded: fnv1a64(feature) & 0xFFFFF)
    }
}

// weight per namespace block. changing these (or tokens or feature names) needs a featureVersion bump
struct BlockWeights: Equatable {
    var weights: [String: Float]

    static let standard = BlockWeights(weights: [
        "c": 1.0,       // content words
        "v": 1.0,       // vision labels
        "flag": 0.8,
        "n": 0.7,       // filename words
        "src": 0.6,     // download source
        "name": 0.5,    // filename patterns
        "pat": 0.5,     // content patterns
        "kind": 0.4,
        "ext": 0.4,
        "from": 0.3,    // folder it came from
        "size": 0.1,
    ])

    subscript(namespace: String) -> Float? {
        weights[namespace]
    }
}

enum FeatureVectorizer {
    // bump when weights, tokenization or feature names change; learned data with another version is dropped
    static let featureVersion = 1

    // by unicode scalar: a token starting with a combining mark would glue onto the ':' as one Character
    static func namespace(of feature: String) -> String? {
        let scalars = feature.unicodeScalars
        guard let colon = scalars.firstIndex(of: ":"), colon != scalars.startIndex else { return nil }
        return String(scalars[..<colon])
    }

    // raw features ("ns:token" -> value, already the max per string) to a unit sparse vector,
    // plus index -> name for this file's why-text. every order here is sorted, never a dictionary's
    static func vectorize(_ raw: [String: Float], weights: BlockWeights = .standard) -> (vector: SparseVector, names: [UInt32: String]) {
        // 1. group by namespace, in name order
        var blocks: [(namespace: String, items: [(String, Float)])] = []
        for feature in raw.keys.sorted() {
            guard let value = raw[feature], value > 0, value.isFinite else { continue }
            guard let namespace = namespace(of: feature) else {
                assertionFailure("feature without a namespace: \(feature)")
                continue
            }
            if blocks.last?.namespace == namespace {
                blocks[blocks.count - 1].items.append((feature, value))
            } else if let index = blocks.firstIndex(where: { $0.namespace == namespace }) {
                blocks[index].items.append((feature, value))
            } else {
                blocks.append((namespace, [(feature, value)]))
            }
        }

        // 2-3. unit length per block, then the block weight
        var weighted: [(String, Float)] = []
        for block in blocks {
            guard let weight = weights[block.namespace] else {
                assertionFailure("no block weight for namespace \(block.namespace)")
                continue
            }
            var squares: Float = 0
            for (_, value) in block.items {
                squares += value * value
            }
            let length = squares.squareRoot()
            guard length > 0, weight > 0 else { continue }
            for (feature, value) in block.items {
                weighted.append((feature, value / length * weight))
            }
        }

        // 4. unit length overall
        var squares: Float = 0
        for (_, value) in weighted {
            squares += value * value
        }
        let total = squares.squareRoot()
        guard total > 0 else { return (SparseVector(), [:]) }

        // 5-6. hash, sum what shares a bucket, sort by index
        weighted.sort { $0.0 < $1.0 }
        var pairs: [(UInt32, Float)] = []
        var names: [UInt32: String] = [:]
        pairs.reserveCapacity(weighted.count)
        for (feature, value) in weighted {
            let index = FeatureHash.index(feature)
            pairs.append((index, value / total))
            if names[index] == nil {
                names[index] = feature
            }
        }
        return (SparseVector(pairs: pairs), names)
    }
}

enum TokenNormalizer {
    // one shared small english list, compared after folding
    static let stopwords: Set<String> = [
        "a", "about", "above", "after", "again", "all", "also", "am", "an", "and", "any", "are", "as", "at",
        "be", "been", "before", "being", "below", "between", "both", "but", "by", "can", "could", "did", "do",
        "does", "doing", "down", "during", "each", "few", "for", "from", "further", "had", "has", "have",
        "having", "he", "her", "here", "hers", "him", "his", "how", "i", "if", "in", "into", "is", "it", "its",
        "just", "me", "more", "most", "my", "no", "nor", "not", "now", "of", "off", "on", "once", "only", "or",
        "our", "ours", "out", "over", "own", "same", "she", "should", "so", "some", "such", "than", "that",
        "the", "their", "theirs", "them", "then", "there", "these", "they", "this", "those", "through", "to",
        "too", "under", "until", "up", "us", "very", "was", "we", "were", "what", "when", "where", "which",
        "while", "who", "whom", "why", "will", "with", "would", "you", "your", "yours",
    ]

    // the plan §4.3: nfc, fold case and diacritics, drop stopwords, keep 2-30 chars, drop tokens without
    // a letter like 2024 or 14.55 (unless keepDigits: folder names, hints, pack triggers), drop a plural s
    static func normalize(_ token: String, keepDigits: Bool = false) -> String? {
        var word = token.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        // stray combining marks and format characters at the edges ("\u{301}ecole")
        while let first = word.unicodeScalars.first, isMark(first) {
            word.unicodeScalars.removeFirst()
        }
        // possessives: "bachelor's" and "bachelor’s" are bachelor
        for suffix in ["'s", "’s"] where word.hasSuffix(suffix) {
            word.removeLast(2)
        }
        word = word.trimmingCharacters(in: CharacterSet(charactersIn: "'’"))
        guard !stopwords.contains(word) else { return nil }
        let length = word.count
        guard length >= 2, length <= 30 else { return nil }
        // prices and numbers are noise as words (pat:money covers prices)
        if !keepDigits && !word.contains(where: \.isLetter) {
            return nil
        }
        if length > 3 && word.hasSuffix("s") && !word.hasSuffix("ss") {
            word.removeLast()
        }
        return word
    }

    private static func isMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark, .format: return true
        default: return scalar.properties.isGraphemeExtend
        }
    }

    // "TanayKumarResume_2025-v2.pdf" -> ["Tanay", "Kumar", "Resume", "2025", "v2"], "CS101_hw3" -> ["CS101", "CS", "hw3", "hw"]:
    // splits on anything not a letter or digit and on camelCase ("HTMLParser" -> HTML, Parser; "CVs" stays whole).
    // a word mixing letters and digits also gives its letter parts, so course codes keep matching
    // destination names (cs101) while "lecture07" still says lecture
    static func filenameWords(_ filename: String) -> [String] {
        words((filename as NSString).deletingPathExtension)
    }

    // the same split for any text: destination names and hints must tokenize like filenames
    static func words(_ text: String) -> [String] {
        let base = Array(text)
        var runs: [String] = []
        var current: [Character] = []

        func flush() {
            if !current.isEmpty {
                runs.append(String(current))
                current.removeAll()
            }
        }

        for (index, character) in base.enumerated() {
            guard character.isLetter || character.isNumber else {
                flush()
                continue
            }
            if let previous = current.last {
                if previous.isLowercase && character.isUppercase {
                    flush()
                } else if previous.isUppercase && character.isUppercase, index + 2 < base.count,
                          base[index + 1].isLowercase && base[index + 2].isLowercase {
                    // "HTMLParser": the P starts a word of 2+ lowercase letters; "CVs" and "IDs" don't split
                    flush()
                }
            }
            current.append(character)
        }
        flush()

        var words: [String] = []
        for run in runs {
            words.append(run)
            let hasLetters = run.contains(where: \.isLetter)
            let hasDigits = run.contains(where: \.isNumber)
            guard hasLetters && hasDigits else { continue }
            // letter parts of "cs101", "lecture07", "hw3"
            var part = ""
            for character in run {
                if character.isLetter {
                    part.append(character)
                } else if !part.isEmpty {
                    words.append(part)
                    part = ""
                }
            }
            if !part.isEmpty {
                words.append(part)
            }
        }
        return words
    }
}
